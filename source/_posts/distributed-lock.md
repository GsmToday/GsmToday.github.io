---
title: 分布式锁实现浅谈(Redis实现方式)
toc: true
thumbnail: /images/5v.jpeg
date: 2019-06-21 09:33:06
author: GSM
tags: Redis
categories: 学习积累
---
和我厂老师傅练功夫系列。另，本文范围只是基于Redis实现。
<!--more-->
## 分布式锁想解决什么问题
Martin Kleppmann 认为一般我们使用分布式锁有两个场景：
- 效率： 使用分布式锁可以避免不同节点重复相同的工作，这些工作会浪费资源，比如用户付了钱之后可能不同节点会发出多封短信；再比如定时任务多个节点执行多次，实际上只需要任务执行一次。
- 正确性：加分布式锁同样可以避免破坏正确性的发生，如果两个节点在同一条数据上操作，比如多个节点机器对同一个订单操作不同的流程有可能会导致该笔订单最后状态出现错误，造成损失。

## 分布式锁特点
- 1.互斥性：和本地锁一样，互斥性是最基本的特性。但是分布式锁需要**保证在不同节点的不同线程**的互斥。
- 2.可重入性： 同一个节点的同一个线程获取了锁之后，那么也可以再次获得这个锁（用的少）。
- 3.不会发生死锁：即使有一个客户端在持有锁期间崩溃而没有主动解锁，也能保证后续客户端能加锁。
- 4.解铃还须系铃人：加锁和解锁必须是同一个客户端，客户端自己不能把别人家的锁给解了。

![](1.png)

## 单机Redis分布式锁实现
分布式锁本质上要实现的目标就是Redis里面占一个“坑”，当别的进程也要来占坑时，发现那里已经有一根“大萝卜”了，就只好放弃或者稍后再试。 占坑一般使用`setnx`, 
只允许一个客户端占坑。先来先占，用完了，再调用del指令。

最基本操作 **distributed-lock 加锁1.0 版本**
```java
setnx lock-key true // 加锁
do the job // 执行任务
del lock-key // 解锁
```
1.0版本有个问题，如果执行逻辑到中间出现异常了，可能会导致del指令没有被调用，这样就会陷入死锁，锁永远得不到释放从而发生死锁。所以需要在拿到锁之后加上一个过期时间，比如5s, 这样即使中间出现异常也可以保证5s之后锁会自动释放。于是 **distributed-lock 加锁2.0 版本：**
```java
setnx lock-key true // 加锁
expire lock-key 5 // 加上过期时间避免死锁
do the job // 执行任务
del lock-key // 解锁
```
但是以上逻辑还是有问题，如果setnx和expire之间服务器进程突然挂掉了，可能是因为机器掉电或者人为导致，就会导致expire得不到执行，也会造成死锁。

这种问题的根源就在于setnx和expire是两条指令而不是原子指令。如果这两条指令可以一起执行就不会出现问题。为了解决这个问题，Redis 2.8版本中，作者加入了set指令的扩展参数，使得expire和setnx可以一起执行，彻底解决了分布式锁的乱象。

**distributed-lock 加锁3.0 版本：**
```java
set lock-key true ex 5 nx //5s超时
del lock-key 
```

3.0版本还有一个问题：如果锁被错误的释放（如超时），或被错误抢占，或因redis问题等导致锁丢失，无法很快感知到。例如：1号线程任务超时，这时候锁过期了，第二个线程重新持有了这把锁， 但是紧接着第一个线程执行完了业务逻辑，就把锁给释放了，第三个线程就会在第二个线程逻辑执行完之间拿到了锁。--- 这就要求自己的锁只能自己解。
**distributed-lock 加锁4.0 版本：**
```
set lock-key random_value ex 5 nx //5s超时
// do sth
eval "if redis.call('get',KEYS[1]) == ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end"
//方案4在3的基础上，增加对 value 的检查，只解除自己加的锁。
//此方案 redis 原生命令不支持，为保证原子性，需要通过lua脚本实现:。
```
此方案更严谨：即使因为某些异常导致锁被错误的抢占，也能部分保证锁的正确释放。并且在释放锁时能检测到锁是否被错误抢占、错误释放，从而进行特殊处理。

推荐使用此方式。

### 注意事项
1.锁的过期时间
锁的过期时间是一个比较重要的变量：

锁的过期时间不能太短，否则在任务执行完成前就自动释放了锁，导致资源暴露在锁保护之外。
锁的过期时间不能太长，否则会导致意外死锁后长时间的等待。除非人为接入处理。
因此建议是根据任务内容，合理衡量锁的过期时间，将锁的过期时间设置为任务内容的几倍即可。
如果实在无法确定而又要求比较严格，可以采用定期 setex/expire 更新锁的过期时间实现。具体可以参考Reddision的看门狗机制，如果加锁的业务没有执行完，就会给锁的过期时间续期一段时间。

2.重试
如果拿不到锁，建议根据任务性质、业务形式进行轮询等待。
等待次数需要参考任务执行时间。

3.基于故障转移实现的缺陷--master挂掉
单点失败问题。如果Redis挂了怎么办？如果只增加一个slave节点解决是行不通的。Redis的主从同步通常是异步的。当正好一个节点挂掉的时候，多个客户端同时取到了锁 

在这种场景（主从结构）中存在明显的竞态:

1. 客户端A从master获取到锁
2. 在master将锁同步到slave之前，master宕掉了。
3. slave节点被晋级为master节点
4. 客户端B取得了同一个资源被客户端A已经获取到的另外一个锁。安全失效！

## 多机Redis分布式锁实现
### RedLock 
RedLock主要解决Redis没有总是可用的保障，解决failover问题。加锁的时候，它会向过半节点发送 set(key, value, nx=True, ex=xxx)指令，只要过半节点set成功，那就认为加锁成功。释放锁时，需要向所有节点发送del 指令。不过Redlock算法还需要考虑出错重试、时钟漂移等很多细节问题，同时因为RedLock需要向多个节点进行读写，意味着相比单实例Redis性能会下降一些。

### 具体实现

在Redis分布式环境中，我们假设有N个Redis master。这些节点完全独立，不存在主从复制或者其他集群协调机制。redlock确保在每（N)个实例上使用此方法获取和释放锁。假设有5个不会同时都宕掉的Redis master节点。

为了取到锁，客户端应该执行以下操作:

1. 获取当前Unix时间，以毫秒为单位。
2. 依次尝试从N个实例，使用相同的key和随机值获取锁。在步骤2，当向Redis设置锁时,客户端应该设置一个网络连接和响应超时时间，这个超时时间应该小于锁的失效时间。例如你的锁自动失效时间为10秒，则超时时间应该在5-50毫秒之间。这样可以避免服务器端Redis已经挂掉的情况下，客户端还在死死地等待响应结果。如果服务器端没有在规定时间内响应，客户端应该尽快尝试另外一个Redis实例。
3. 客户端使用当前时间减去开始获取锁时间（步骤1记录的时间）就得到获取锁使用的时间。当且仅当从大多数（这里是3个节点）的Redis节点都取到锁，并且使用的时间小于锁失效时间时，锁才算获取成功。
4. 如果取到了锁，key的真正有效时间等于有效时间减去获取锁所使用的时间（步骤3计算的结果）。
5. 如果因为某些原因，获取锁失败（没有在至少N/2+1个Redis实例取到锁或者取锁时间已经超过了有效时间），客户端应该在所有的Redis实例上进行解锁（即便某些Redis实例根本就没有加锁成功）。

这个方案的缺点就是太重，通常不被推荐。如果很在乎高可用性，希望挂了一台Redis完全不受影响，那么应该考虑redlock.

### Jedis 实现
Java实现：
```pom
    <dependency>
        <groupId>redis.clients</groupId>
        <artifactId>jedis</artifactId>
        <version>2.9.0</version>
    </dependency>
```

```java
    private static final String SET_IF_NOT_EXIST = "NX";
    private static final String SET_WITH_EXPIRE_TIME = "PX";
    private static final String LOCK_SUCCESS = "OK";

    public static boolean tryGetDistributedLock(Jedis jedis, String lockKey, String requestId, int expireTime) {
        /**
         * arg1 : key
         * arg2: value
         * arg3: nxxx, NX 代表set if not exist, 即当key 不存在的时候，进行set; 若key已经存在，不做任何操作
         * arg4: expx, PX 代表加个过期的设置
         * arg5: timeout 过期时间
         */
        String result = jedis.set(lockKey, requestId, SET_IF_NOT_EXIST, SET_WITH_EXPIRE_TIME, expireTime);
        if (LOCK_SUCCESS.equals(result)) {
            return true;
        }
        return false;
    }
```
再看解锁。**distributed-lock 解锁1.0 版本**如下：
```
del distributed-lock // 解锁
```
这是最简单的解锁方法，但是容易出现问题：不预先判断锁的拥有者而直接解锁，会导致任何客户端都可以随时进行解锁，即使这把锁不是它的 -- 违背了解铃还需系铃人。

**distributed-lock 解锁2.0 版本**：
```
lockId = get distributed-lock 
if(lockId.equals(requestId)) {
    // 若在此时，这把锁突然不是这个客户端的，则会误解锁。
    del distributed-lock
}
```
但是2.0版本也不是完美的，如代码注释，问题在于如果调用jedis.del()方法的时候，这把锁已经不属于当前客户端的时候会解除他人加的锁。那么是否真的有这种场景？答案是肯定的，比如客户端A加锁，一段时间之后客户端A解锁，在执行jedis.del()之前，锁突然过期了，此时客户端B尝试加锁成功，然后客户端A再执行del()方法，则将客户端B的锁给解除了。

[此博客](https://wudashan.cn/2017/10/23/Redis-Distributed-Lock-Implement/)提供了一种功能3.0版本方法，通过Lua实现原子性解锁。

**distributed-lock 解锁3.0 版本**：
```java
    /**
     * 释放分布式锁
     * @param jedis Redis客户端
     * @param lockKey 锁
     * @param requestId 请求标识
     * @return 是否释放成功
     */
    public static boolean releaseDistributedLock(Jedis jedis, String lockKey, String requestId) {

        String script = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end";
        Object result = jedis.eval(script, Collections.singletonList(lockKey), Collections.singletonList(requestId));

        if (RELEASE_SUCCESS.equals(result)) {
            return true;
        }
        return false;

    }
```

### Spring实现
到这里，基本上一个完整的Java Redis分布式锁已经实现了。但是在生产环境发现上述代码并不实用。因为我们的生产环境采用了Spring的template实现redis 客户端的封装，Spring封装的template并不精细，并没有distributed-lock 加锁3.0 版本：`set distributed-lock true ex 5 nx`的setnx+expire的原子性实现。所以只能用下面的时间戳方式缓解：
```
// 每个进程一个随机数，用来实现“解铃还须系铃人”功能。
public class SoaTask extends BasicTask {
    public static final String  TASKKEY = ":task";
    public static final Integer EXPIRE  = 15;
    public static volatile String code = "default";

    @PostConstruct
    public void init() {
        code = UUID.randomUUID().toString();
    }
}
```

```java
   protected boolean lock() {
        boolean lockRes = codisCacheTemplate.setIfAbsent(SoaTask.TASKKEY+getTimestamp(), SoaTask.code);
        if (lockRes) {
            // 任务一天执行一次
            codisCacheTemplate.expire(SoaTask.TASKKEY+getTimestamp(), 86400);
        }

        return lockRes;
    }

    protected boolean unlock() {
        if (codisCacheTemplate.get(SoaTask.TASKKEY+getTimestamp()).equals(SoaTask.code)) {
            codisCacheTemplate.del(SoaTask.TASKKEY+getTimestamp());
        }
        return true;
    }

    protected void doJob() {
        try {
            if (lock()) {
                //do job
            }
        }finally {
            unlock();
        }
    }
    private String getTimestamp() {
        SimpleDateFormat formatter = new SimpleDateFormat(PATTERN_YYYYMMDD);
        String formatStr =formatter.format(new Date());
        return formatStr;
    }

```
时间戳+随机数做分布式锁redis key的方式本质上是通过时间戳做一个超时方案，但时间戳的粒度需要结合分布式任务执行时间来操作。例如我们的分布式定时任务是1天执行一次，那么我就把时间戳设置为YYYYMMDD格式的，这样第二天的分布式锁的key即使不释放，key也是新的，新任务是可以执行的，以此避免了死锁。另外加上随机数保证了自己的锁只能自己解。

### Reddison
Redisson是Java语言编写的基于Redis的客户端。分布式锁的实现具有借鉴意义。为了解决“加锁线程在没有解锁之前崩溃而出现死锁“的问题，不同于Redis中通过设置超时时间来处理。Reddison采用了新的处理方式：Redisson内部提供了一个监控锁的看门狗，它的作用是在Redis实例被关闭前不断延长锁的有效期。跟Zookeeper类似，Redisson也提供了这几种分布式锁：可重入锁，公平锁，联锁，红锁，读写锁等。

## 参考
1. https://wudashan.cn/2017/10/23/Redis-Distributed-Lock-Implement/
2. https://mp.weixin.qq.com/s/eU_2lh1slxv3H0v3gFk37Q
3. https://mp.weixin.qq.com/s/doYn9riDh4AdpTyT4OgCwA
4. [Reddision](https://blog.csdn.net/wutengfei_java/article/details/100699538)
5. [基于Redis的分布式锁到底安全吗](https://mp.weixin.qq.com/s/JTsJCDuasgIJ0j95K8Ay8w)