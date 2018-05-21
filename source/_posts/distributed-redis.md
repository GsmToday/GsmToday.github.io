---
title: 分布式Redis探讨
toc: true
banner: /images/mouse.jpg
date: 2018-03-06 17:09:08
author: GSM
tags:
  - Redis
categories: 中间件
---

## 为什么需要使用Redis集群
Redis是目前互联网热点数据缓存解决方案的技术选型之一。在大型Web应用中，缓存存储的数据量巨大，在这种情况单机Redis难以支撑服务，分布式横向扩展Redis多实例协同运行。另外，Redis的工作模型是单线程工作的，对于目前硬件机器大多是多核CPU，几十G内存的主机来说是一种浪费。更为实际的应用方式是，一台机器同时运行多个Redis实例。

<!-- more -->
## 集群遇到的问题
相对于单机，分布式服务会遇到很多问题，本文试图探讨并解决：
- Redis的主从复制是怎么实现的？
- Redis的集群模式是怎么实现的？
- Redis的key是如何寻址的？
- 使用Redis如何设计分布式锁？使用ZK可以吗?如何实现。

## Redis集群实现方案
分片(Sharding)，顾名思义是分布式服务将数据根据其特征（一般是根据key进行哈希）分发到不同的Redis服务器实例上。通常有客户端分片，服务端分片以及代理分片三种方式。
### 客户端分片
这种方案是将分片工作放在Redis客户端。利用哈希算法对数据的key进行散列，特定的key映射到特定的Redis实例上，这样客户端就知道该向哪个Redis节点操作数据。目前Jedis已经支持客户端分片。

客户端分片的好处是可以不依赖第三方分布式中间件，客户端和Redis服务端都处于一种轻量灵活的状态。但是缺点非常明显，比如扩容--当想要增加Redis实例的时候，Rehash进行数据迁移的代价是非常大的。再比如，Redis分布式服务经常遇到的问题利用主从容错，保证master/slave实例一致会给客户端带来不可避免的问题。
### 服务器分片
服务器分片典型的产品是Redis 3.0。Redis 3.0提供的Redis Cluster是一种Redis实例P2P模型，依靠Gossip协议进行消息同步。在服务端逻辑上分成16384个slot槽，客户端发送到Redis cluster的key会哈希分发到16384个槽中的某个。而Redis集群中的Redis实例负责分摊6384个槽中的一部分。当Redis实例横向扩展时候，只需要对槽做再分配，将槽中的键值对迁移。另外，对于Redis实例容灾问题，官方推荐将Redis配置成主从结构，即一个master节点，多个slave从节点。如果主节点失效，Redis Cluster会根据选举算法从Slave节点中选择一个上升为主节点，整个集群继续对外提供服务。

这种架构对于客户端来说，整个Cluster被看做一个整体，客户端可以连接任意一个Redis实例进行操作，就像操作单一Redis实例一样。大大解放了Redis客户端。

但是，正如[Codis作者所说](https://studygolang.com/articles/3126), 服务端分片将分布式的逻辑和存储引擎的逻辑绑定在了一起，集群升级困难，运维困难。没有一个中心，无法获知集群处于什么状态。

### Proxy-based代理分片
该方案引入一个代理层(Proxy)将分片工作交给这一层从而对多Redis实例进行统一管理和分配，使Redis客户端只需要向Proxy操作，代理接收客户端的数据请求，根据key做哈希映射，分发给Redis实例。实现了Redis Server解耦，Redis Server只专门做Redis存储。代理分片的重要设计思想是：将**分布式的逻辑和存储引擎隔离**。典型的产品是Twemproxy和Codis。

这种代理分片的好处是结合了服务器分片和客户端分片的优势，即服务端实例彼此独立，线性可伸缩，同时分片可以集中管理（proxy来管理）。

不过，难以避免的缺点是部署起来很麻烦，例如codis组件繁多，部署起来困难。另外，增加了一层代理会增加网络转发开销。[Codis作者也承认](https://studygolang.com/articles/3128),单机且不开pipeline的情况下，大概会损失40%左右性能（不过这对于多Proxy多Redis实例来说并不是个事儿）。

## Codis设计思想
Codis 3.x 由以下组件组成：
- Codis Server 可以理解为Redis Server, 存储和分布式逻辑隔离。
- Codis Proxy 客户端连接Redis的代理服务。负责分布式逻辑。
    + 对于同一个业务集群而言，可以同时部署多个codis-proxy实例以实现proxy HA
    + 不同codis-proxy之间由codis-dashboard保证状态同步
- Codis Dashboard 集群管理工具。支持 codis-proxy、codis-server 的添加、删除，以及据迁移等操作。在集群状态发生改变时，codis-dashboard 维护集群下所有 codis-proxy 的状态的一致性。
    + 对于同一个业务集群而言，同一个时刻 codis-dashboard 只能有 0个或者1个；
    + 所有对集群的修改都必须通过 codis-dashboard 完成。
- Codis Admin 集群管理的命令行工具。
    + 可用于控制 codis-proxy、codis-dashboard 状态以及访问外部存储。
- Codis FE 集群管理界面。
    + 通过配置文件管理后端 codis-dashboard 列表，配置文件可自动更新。
- Zookeeper 负责分布式服务的服务发现。用来存放数据路由表和codis-proxy节点的原信息，codis-config发起的命令都会通过zookeeper同步到各个存活的codis-proxy.
![Codis架构](architecture.png)

### Codis数据存储
Codis借鉴了Redis的Pre-sharding思想,将数据根据key进行哈希`crc32(key)%1024`映射存储在1024个slot(0-1023)里面。slot是逻辑概念，每个slot的数据实际上由某个特定的Redis实例物理存储。即一个slot对应一个codis-group. 一个codis-group为codis redis 实例单元（一个master和n个slave组成。）

例如系统有两个Redis Servier Group, 那么Redis Servier Group与slot对应关系如下：
```
Redis Servier Group            slot
1                              0~499
2                              500~1023
```

当新增一个codis group时候，slot会重新分配。Codis重新分配有两种方法：
第一种，通过Codisconfig手动重新分配，指定每个Redis Servier Group对应的slot的范围。
```
Redis Servier Group            slot
1                              0~499
2                              500~699
3                              700-1023
```
第二种：通过Codis管理工具Codisconfig的rebalance功能，会自动根据每个Redis Server Group的内存对slot进行迁移，以实现数据的均衡
### Codis数据迁移
当Codis扩容或者缩容时候就会进行数据迁移。数据迁移的最小单位是slot。而对于每个Redis实例来说是没有分布式逻辑在其中的，它们只是实现proxy关于数据传输的指令： 选取特定的slot中的数据传输给另一个Redis实例，传输成功后，把本地的数据删除。整个过程是原子的。

引用[dongxu.h](https://studygolang.com/articles/3127)一次典型的迁移流程：

1. codis-config 发起迁移指令如 pre_migrate slot_1 to group 2

2. codis-config 等待所有的 proxy 回复收到迁移指令, 如果某台 proxy 没有响应, 则标记其下线 (由于proxy启动时会在zk上注册一个临时节点, 如果这个proxy挂了, 正常来说, 这个临时节点也会删除, 在codis-config发现无响应后, codis-config会等待30s, 等待其下线, 如果还没下线或者仍然没有响应, 则codis-config 将不会释放锁, 通知管理员出问题了) 相当于一个2阶段提交

3. codis-config 标记slot_1的状态为 migrate, 服务该slot的server group改为group2, 同时codis-config向group1的redis机器不断发送 SLOTSMGRT 命令, target参数是group2的机器, 直到group1中没有剩余的属于slot_1的key

4. 迁移过程中, 如果客户端请求 slot_1 的 key 数据, proxy 会将请求转发到group2上, proxy会先在group1上强行执行一次 MIGRATE key 将这个键值提前迁移过来. 然后再到group2上正常读取

5. 迁移完成, 标记slot_1状态为online

### Codis HA主从复制
Codis的HA可以分为Redis HA和Proxy HA.

Codis 引入了Redis Server Group, 通过指定一个Master Redis实例和多个slave Redis实例实现了Redis的高可用。但是当一个Master Redis挂掉之后，Codis是不会自动提升Slave为Master的。[Codis作者](https://studygolang.com/articles/3128)提到之所以这么设计是因为考虑到主从数据一致性的问题：当Master挂掉之后，Master上的数据是否已经同步到Slave上是没法保证的，所以不如直接报个错给用户。如果想实现salve自动提升为master，可以使用codis-ha工具，该工具会在检测到master挂掉的时候主动应用主从切换策略，提升单个salve成为新的master。

对于Proxy HA，由于proxy是无状态的，当加入多个proxy，并且每个新增proxy都会去Zookeeper上注册，就会使每个proxy上视角一致从而实现了高可用。


### Codis分布式锁解决方案
对于Redis并发冲突，可以使用乐观锁和分布式锁进行解决。乐观锁的缺点在于，随着计算机并发数的增加，程序的重试的次数可能会越来越多，导致资源被白白浪费。因此可以通过锁来减少对WATCH命令的使用，从而达到避免重试，提升性能并在某些情况简化代码。

在Redis集群多机器的情况下，推荐不直接使用操作系统级别或者是编程语言级别的锁，而是使用Redis构建锁。这和“范围”有关：为了对Redis存储的数据进行排他性访问，客户端需要访问一个锁，这个锁必须定义在一个可以让所有客户端都看得见的范围之内 - Redis本身，因此我们需要**把锁构建在Redis里面**，进而实现一个分布式锁。

错误的实现锁可能出现的问题：
1. 持有锁的进程因为操作时间过长儿导致锁被自动释放，但进程本身并不知道这一点，甚至还可能错误释放掉其他进程持有的锁。
2. 一个持有锁并打算执行长期操作的进程已崩溃，但其他想要获取锁的进程不知道哪个进程持有着锁，也无法检测出持有锁的进程已经崩溃，只能白白等待锁被释放
3. 在上一个进程持有的锁过期之后，其他多个进程同时尝试获取锁，并且都获取了锁
4. 情况1和情况23同时出现，导致多个进程获得了锁，而每个进程都以为自己是唯一一个获得锁的进程。

在Codis中，Codis在做任何操作的时候，都会到ZooKeeper拿一个锁以保证是唯一的操作实例，这也防止了路由表被改坏。尤其在数据迁移的时候，通过锁保证了不可能同时有多个slots处于迁移状态。

## 参考资料
0. [Codis官方文档](https://github.com/CodisLabs/codis/blob/release3.2/doc/tutorial_zh.md)
1. [Codis作者谈设计思想1-3](https://studygolang.com/articles/3127)
2. [知乎关于Redis集群讨论](https://www.zhihu.com/question/21419897)
3. 彭东稳：http://www.ywnds.com/?p=6579
4. 《Redis in Action》
5. [基于Zookeeper的分布式锁](http://www.dengshenyu.com/java/%E5%88%86%E5%B8%83%E5%BC%8F%E7%B3%BB%E7%BB%9F/2017/10/23/zookeeper-distributed-lock.html)
6. [Codis作者黄东旭：细说分布式Redis架构设计和那些踩过的坑
](http://dbaplus.cn/news-141-270-1.html)


