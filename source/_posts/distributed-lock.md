---
title: 分布式锁实现浅谈
toc: true
thumbnail: /images/5v.jpeg
date: 2019-06-21 09:33:06
author: GSM
tags: Redis
categories: 学习积累
---
和我厂老师傅练功夫系列。
<!--more-->
## 分布式锁想解决什么问题
Martin Kleppmann 认为一般我们使用分布式锁有两个场景：
- 效率： 使用分布式锁可以避免不同节点重复相同的工作，这些工作会浪费资源，比如用户付了钱之后可能不同节点会发出多封短信；再比如定时任务多个节点执行多次，实际上只需要任务执行一次。
- 正确性：加分布式锁同样可以避免破坏正确性的发生，如果两个节点在同一条数据上操作，比如多个节点机器对同一个订单操作不同的流程有可能会导致该笔订单最后状态出现错误，造成损失。

## 分布式锁特点
- 1.互斥性：和本地锁一样，互斥性是最基本的特性。但是分布式锁需要**保证在不同节点的不同线程**的互斥。
- 2.可重入性： 同一个节点的同一个线程如果获取了锁之后，那么也可以再次获得这个锁（用的少）。
- 3.不会发生死锁：即使有一个客户端在持有锁期间崩溃而没有主动解锁，也能保证后续客户端能加锁。
- 4.解铃还须系铃人：加锁和解锁必须是同一个客户端，客户端自己不能把别人家的锁给解了。

## Redis实现
分布式锁本质上要实现的目标就是Redis里面占一个“坑”，当别的进程也要来占坑时，发现那里已经有一根“大萝卜”了，就只好放弃或者稍后再试。 占坑一般使用`setnx`, 
只允许一个客户端占坑。先来先占，用完了，再调用del指令。

最基本操作 **distributed-lock 加锁1.0 版本**
```java
setnx lock-key true // 加锁
do the job // 执行任务
del lock-key // 解锁
```
1.0版本有个问题，如果执行逻辑到中间出现异常了，可能会导致del指令没有被调用，这样就会陷入死锁，锁永远得不到释放。所以需要在拿到锁之后加上一个过期时间，比如5s, 这样即使中间出现异常也可以保证5s之后锁会自动释放。于是 **distributed-lock 加锁2.0 版本：**
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
set distributed-lock true ex 5 nx
```
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
时间戳+随机数做分布式锁redis key的方式本质上是通过时间戳做一个超时方案，但时间戳的粒度需要结合分布式任务执行时间来操作。例如我们的分布式定时任务是1天执行一次，那么我就把时间戳设置为YYYYMMDD格式的，这样第二天的分布式锁的key即使不释放，key也是新的，新任务是可以执行的，以此避免了死锁。

## 参考
1. https://wudashan.cn/2017/10/23/Redis-Distributed-Lock-Implement/
