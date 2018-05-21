---
title: RocketMQ源码分析6--关于RocketMQ你想知道的Questions
banner: /images/lion.png
date: 2018-04-31 10:34:51
author: GSM
tags:
  - RocketMQ
categories: 中间件
---
既见树木，又见森林。
<!-- more -->
1.RocketMQ如何保证**严格的消息顺序**？

消息顺序分为：普通顺序消息和严格顺序消息。

普通顺序消息在正常情况下可以保证完全的顺序消息，但是一旦发生通信异常，Broker重启，由于队列总数发生变化，hash取模后定位的队列会变化，产生短暂的消息顺序不一致。如果业务能容忍集群在异常情况下（如某个Broker宕机或者重启）下，消息短暂的乱序，使用普通顺序方式比较合适。

严格顺序消息在无论正常异常情况下都能保证顺序，但是牺牲了分布式Failover特性，即Broker集群中只要有一台机器不可用，整个集群都不可用，服务可用性大大降低。目前已知的应用只有数据库binlog同步强依赖严格顺序消息，其他应用绝大部分都可以容忍短暂乱序。推荐使用普通的顺序消息。

**顺序消息**是RocketMQ功能特性上的一个卖点。在RocketMQ中，主要指的是局部顺序，即一类消息为满足顺序性，必须由Producer**单线程顺序发送，且发送到同一个队列**，这样Consumer就可以按照Produer发送的顺序去消费消息。

从源码角度分析RocketMQ怎么实现发送顺序消息。

RocketMQ通过轮询所有队列的方式来确定消息被发送到哪一个队列（负载均衡策略）。比如下面的示例中，订单号相同的消息会被先后发送到同一个队列中：
```java
// RocketMQ通过MessageQueueSelector中实现的算法来确定消息发送到哪一个队列上
// RocketMQ默认提供了两种MessageQueueSelector实现：随机/Hash
// 当然你可以根据业务实现自己的MessageQueueSelector来决定消息按照何种策略发送到消息队列中
SendResult sendResult = producer.send(msg, new MessageQueueSelector() {
    @Override
    public MessageQueue select(List<MessageQueue> mqs, Message msg, Object arg) {
        Integer id = (Integer) arg;
        int index = id % mqs.size();
        return mqs.get(index);
    }
}, orderId);
```
在获取到路由信息以后，会根据MessageQueueSelector实现的算法来选择一个队列，同一个OrderId获取到的肯定是同一个队列。
```java
private SendResult send()  {
    // 获取topic路由信息
    TopicPublishInfo topicPublishInfo = this.tryToFindTopicPublishInfo(msg.getTopic());
    if (topicPublishInfo != null && topicPublishInfo.ok()) {
        MessageQueue mq = null;
        // 根据我们的算法，选择一个发送队列
        // 这里的arg = orderId
        mq = selector.select(topicPublishInfo.getMessageQueueList(), msg, arg);
        if (mq != null) {
            return this.sendKernelImpl(msg, mq, communicationMode, sendCallback, timeout);
        }
    }
}
```

---
2.RocketMQ保证消息不重复吗？

MQ的消息不重复指无论是发送阶段还是消费消息阶段，都不允许发送重复的消息。先说结论，RocketMQ不能严格保证不重复，但是正常情况下很少会出现重复发送or消费。只有网络异常，consumer启停的是可能会出现。

重复消息的本质是网络调用的不确定性。只要网络交换数据，就无法避免这个问题，所以只能绕过这个问题以姐姐。那么问题就变成了：如果消费端收到两条一样的消息，应该怎么处理？

- 消费端自己处理：消费端处理消息的业务逻辑保持幂等
- 保证每条消息都有唯一编号且保证消息处理成功与去重的日志同事出现 - 利用一张日志表来记录已经处理成功的消息的ID，如果新到的消息ID已经在日志表中，那么就不再处理这条消息。

第1条解决方案，很明显应该在消费端实现，不属于消息系统要实现的功能。第2条可以消息系统实现，也可以业务端实现。正常情况下出现重复消息的概率其实很小，如果由消息系统来实现的话，肯定会对消息系统的吞吐量和高可用有影响，所以最好还是由业务端自己处理消息重复的问题，这也是RocketMQ不解决消息重复的问题的原因。

RocketMQ不保证消息不重复，如果你的业务需要保证严格的不重复消息，需要你自己在业务端去重

关于消息顺序&重复，更多推荐阅读：
1. [travi's blog](https://blog.csdn.net/chunlongyu/article/details/53977819)
2. [CHEN川‘s简书](https://www.jianshu.com/p/453c6e7ff81c)
---

3.RocketMQ为什么不采用Zookeeper而自己开发了NameServer?

首先，ZooKeeper可以提供Master/Slave选举功能，比如Kafka一个topic由多个partition，每个partition有1个master+多个slave，Kafka使用ZK给每个分区选一个机器作为Master。这里Master/Slave是动态的，Master挂了会有1个Slave切换成Master.

但对于RocketMQ来说，不需要选举，Master/Slave各是一台机器，角色固定。当一个Master挂了，可以写到其他Master上，但是不会Slave切换成Master. 这种简化，使RocketMQ可以不依赖ZK就很好的管理了Topic和Queue以及物理机器的映射，也实现了高可用。

其次，RockeqMQ集群中，需要有构件来处理一些通用数据，比如broker列表，broker刷新时间，虽然ZooKeeper也能存放数据，并有一致性保证，但处理数据之间的一些逻辑关系却比较麻烦，而且数据的逻辑解析操作得交给ZooKeeper客户端来做，如果有多种角色的客户端存在，自己解析多级数据确实是个麻烦事情；

既然RocketMQ集群中没有用到ZooKeeper的一些重量级的功能，只是使用ZooKeeper的数据一致性和发布订阅的话，与其依赖重量级的ZooKeeper，还不如写个轻量级的NameServer，NameServer也可以集群部署，NameServer与NameServer之间无任何信息同步，只有一千多行代码的NameServer稳定性肯定高于ZooKeeper，占用的系统资源也可以忽略不计，何乐而不为？

---

4.RocketMQ怎么处理**亿级消息的堆积的**？在保证了堆积亿级消息后，怎么保持**写入低延迟**？

MQ的一个很重要的一个功能是挡住并缓冲数据洪峰，削峰填谷，从而保证后端系统的稳定性。因此RocketMQ的broker端需要具备一定的消息堆积能力（官方数据是支持亿级消息堆积）。

Broker在接收到消息后，会将其持久化到本地磁盘的文件中。之所以没有选择持久化到远程DB或者KV数据库，个人认为可以减少网络开销，还可以避免因为带宽原因可能影响到消息的发送和消费的TPS。Broker通过使用Linux的**零拷贝技术**保证了提高了文件高并发读写。具体实现为：Broker通过Java的MappedByteBuffer(CommitLog, CQ等的源码都使用到了MappedByteBuffer)使用**mmap技术**, 将文件直接映射到用户态的内存地址, Broker可以像操作内存一样操作文件 - 直接操作Linux操作系统的PageCache，这样就可以直接操作内存中的数据而不需要每次都通过IO去物理磁盘写文件。因此可以RocketMQ存储得以实现亿级消息堆积，并且保持了低写入延迟。

---
5.RocketMQ消息**订阅模式**是什么？

两种消息读取模式 ： Push or Pull。实际上，在RocketMQ中无论是Push还是Pull, **底层都是通过Consumer从Broker拉消息实现的**。为了做到能够实时接收消息，RocketMQ使用长轮询方式，保证消息实时性和Push方式一致。这种长轮询类似Web QQ收发消息机制。

---

6.RocketMQ对于**负载均衡**有哪些设计？
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

7.RocketMQ是怎么做**消息失败重试机制**的？

https://my.oschina.net/xinxingegeya/blog/1584617

---

8.RocketMQ是怎么设计事务机制的？

分布式事务涉及到两阶段提交问题。RocketMQ通过offset方式实现分布式事务。RocketMQ把消息的发送分成了两个阶段：Prepare阶段和确认阶段。
（1） 发送Prepared消息
（2） updateDB
（3) 根据updateDB结果成功或者失败，确认或者取消Prepare消息。
如果前两步执行成功了，最后一步失败了。由于**RocketMQ会定期扫描所有的Prepared消息**，询问发送方，到底是要确认这条消息发出去了，还是取消这条消息。

[参考Travis‘s blog](https://blog.csdn.net/chunlongyu/article/details/53844393)

---
9.RocketMQ是怎么“天然分布式的”？

producer, consumer, broker, nameserver都可以分布式，集群部署，消除单点故障。

---
[推荐jaskey文章总结][http://jaskey.github.io/blog/2016/12/19/rocketmq-rebalance/]
https://www.jianshu.com/p/453c6e7ff81c

http://mp.weixin.qq.com/s/6PmcXJZVyWYZPssveeNkIw