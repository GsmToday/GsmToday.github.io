---
title: RocketMQ源码分析6--关于RocketMQ你想知道的Questions
banner: /images/lion.png
date: 2018-04-31 10:34:51
author: GSM
tags:
  - RocketMQ
categories: 消息队列
---
既见树木，又见森林。
<!-- more -->
1.RocketMQ如何保证**严格的消息顺序**？

**顺序消息**是RocketMQ功能特性上的一个卖点。RocketMQ可以实现全局保序。需要重点说一下，这里的全局是有前提，针对某个唯一标识（能够被Hash成唯一标识），比方说大卖家账号，某类产品的订单等。其技术实现原理也相对比较简单，保证对通道的单一实例操作，如单进程、单线程写，单进程、线程读。

更多推荐阅读：https://blog.csdn.net/chunlongyu/article/details/53977819

---

2.RocketMQ为什么不采用Zookeeper而自己开发了NameServer?

首先，ZooKeeper可以提供Master/Slave选举功能，比如Kafka一个topic由多个partition，每个partition有1个master+多个slave，Kafka使用ZK给每个分区选一个机器作为Master。这里Master/Slave是动态的，Master挂了会有1个Slave切换成Master.

但对于RocketMQ来说，不需要选举，Master/Slave各是一台机器，角色固定。当一个Master挂了，可以写到其他Master上，但是不会Slave切换成Master. 这种简化，使RocketMQ可以不依赖ZK就很好的管理了Topic和Queue以及物理机器的映射，也实现了高可用。

其次，RockeqMQ集群中，需要有构件来处理一些通用数据，比如broker列表，broker刷新时间，虽然ZooKeeper也能存放数据，并有一致性保证，但处理数据之间的一些逻辑关系却比较麻烦，而且数据的逻辑解析操作得交给ZooKeeper客户端来做，如果有多种角色的客户端存在，自己解析多级数据确实是个麻烦事情；

既然RocketMQ集群中没有用到ZooKeeper的一些重量级的功能，只是使用ZooKeeper的数据一致性和发布订阅的话，与其依赖重量级的ZooKeeper，还不如写个轻量级的NameServer，NameServer也可以集群部署，NameServer与NameServer之间无任何信息同步，只有一千多行代码的NameServer稳定性肯定高于ZooKeeper，占用的系统资源也可以忽略不计，何乐而不为？

---

3.RocketMQ怎么处理**亿级消息的堆积的**？在保证了堆积亿级消息后，怎么保持**写入低延迟**？

MQ的一个很重要的一个功能是挡住并缓冲数据洪峰，削峰填谷，从而保证后端系统的稳定性。因此RocketMQ的broker端需要具备一定的消息堆积能力（官方数据是支持亿级消息堆积）。

Broker在接收到消息后，会将其持久化到本地磁盘的文件中。之所以没有选择持久化到远程DB或者KV数据库，个人认为可以减少网络开销，还可以避免因为带宽原因可能影响到消息的发送和消费的TPS。Broker通过使用Linux的**零拷贝技术**保证了提高了文件高并发读写。具体实现为：Broker通过Java的MappedByteBuffer(CommitLog, CQ等的源码都使用到了MappedByteBuffer)使用**mmap技术**, 将文件直接映射到用户态的内存地址, Broker可以像操作内存一样操作文件 - 直接操作Linux操作系统的PageCache，这样就可以直接操作内存中的数据而不需要每次都通过IO去物理磁盘写文件。因此可以RocketMQ存储得以实现亿级消息堆积，并且保持了低写入延迟。

---
4.RocketMQ消息**订阅模式**是什么？

两种消息读取模式 ： Push or Pull。实际上，在RocketMQ中无论是Push还是Pull, **底层都是通过Consumer从Broker拉消息实现的**。为了做到能够实时接收消息，RocketMQ使用长轮询方式，保证消息实时性和Push方式一致。这种长轮询类似Web QQ收发消息机制。

---

5.RocketMQ对于**负载均衡**有哪些设计？
关于RocketMQ的负载均衡讨论，需要分为Broker端，Producer端，Consumer端三处来看是如何支持横向扩展和负载均衡的。

- Broker端：

在RocketMQ中，一个Broker是由一台Master机器+一台或者多台Slave机器组成的逻辑概念。Master和Slave之间的数据同步或者为同步双写，或者为异步复制（可配）。当Broker需要横向扩展时，只需要增加Broker，然后新增该Broker和topic的路由关系，这样对于Broker的负载由更多的Broker分担。

消息的topic路由信息通过NameServer暴露给客户端，客户端通过NameServer可以获取topic对应的多个分布在多个broker上的message queue。客户端会把请求分摊到不同的CQ上，进而分摊到不同的Broker上，这样消息的存储和转发都得到了负载均衡。

- Producer端

Producer端会通过轮询RoundRobin的方式写入消息到服务端中的某个CQ(CQ个数固定，默认配置)，从而达到消息均匀地生产到不同的CQ上。 而每个CQ分布在不同的broker上。所以对于Producer来说，消息会轮询均匀发送到不同的broker上。

- Consumer端：

在集群消费模式下，每条消息需要投递到订阅这个topic的ConsumerGroup下的一个Consumer实例即可。由于Consumer在消费消息时候是根据topic到CQ上查找消息在CommitLog的Offset。所以问题可以转换为：**Consumer多台实例怎么到这个topic的多个ConsumeQueue上消费**。默认的算法是AllocateMessageQueueAveragely：即每个消费者实例可以拿到相同数量的CQ。另外，如果想要水平扩展消费能力的话，可以增加consumer实例。

另外集群模式下，每个CQ只能分配给一个实例。这是由于如果多个实例同时消费到一个queue，会导致同一个消息被**重复消费**。 

---

6.RocketMQ是怎么做**消息失败重试机制**的？

https://my.oschina.net/xinxingegeya/blog/1584617

---

7.RocketMQ是怎么设计事务机制的？
事务消息是指可以用来实现最终一致性的分布式事务。

https://blog.csdn.net/chunlongyu/article/details/53844393

---
8.RocketMQ是怎么“天然分布式的”？
producer, consumer, broker, nameserver都可以分布式，集群部署，消除单点故障。

---
[推荐jaskey文章总结][http://jaskey.github.io/blog/2016/12/19/rocketmq-rebalance/]
https://www.jianshu.com/p/453c6e7ff81c

http://mp.weixin.qq.com/s/6PmcXJZVyWYZPssveeNkIw