---
title: RocketMQ源码分析6--关于RocketMQ你想知道的Questions
thumbnail: /images/lion.png
date: 2018-04-31 10:34:51
author: GSM
tags:
  - RocketMQ
categories: 学习积累
---
既见树木，又见森林。
<!-- more -->
<font color="blue"> 1.RocketMQ如何保证消息顺序？ </font>
消息顺序是指消息消费时，能按照发送的顺序来消费。例如：一个订单产生了 3 条消息，分别是订单创建、订单付款、订单完成。消费时，要按照这个顺序消费才有意义。但同时订单之间又是可以并行消费的。

消息顺序分为：普通顺序消息和严格顺序消息。

在RocketMQ中，只保证普通顺序消费。普通顺序消费的实现：必须由Producer**单线程顺序发送，且发送到同一个队列**，这样Consumer就可以按照Produer发送的顺序去消费消息。

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
<font color="blue"> 2.RocketMQ保证消息不重复吗？ </font>

先说结论：RocketMQ不保证消息不重复，如果你的业务需要保证严格的不重复消息，需要业务端去重。

MQ的消息不重复指无论是发送阶段还是消费消息阶段，都不允许发送重复的消息。先说结论，RocketMQ不能严格保证不重复，但是正常情况下很少会出现重复发送or消费。只有网络异常，consumer启停的是可能会出现。

重复消息的本质是网络调用的不确定性。只要网络交换数据，就无法避免这个问题，所以只能绕过这个问题以解决。那么问题就变成了：如果消费端收到两条一样的消息，应该怎么处理？

- 消费端自己处理：消费端处理消息的业务逻辑保持幂等（生产场景常见。例如在处理支付回调事件，先查询订单状态，如果发现用户订单的状态已经正常流转下去，就不再操作。 否则再触发一次订单基于当前支付事件的变更操作）
- 保证每条消息都有唯一编号且保证消息处理成功与去重的日志同时出现 - 利用一张日志表来记录已经处理成功的消息的ID，如果新到的消息ID已经在日志表中，那么就不再处理这条消息。

关于消息顺序&重复，更多推荐阅读：
1. [travi's blog](https://blog.csdn.net/chunlongyu/article/details/53977819)
2. [CHEN川‘s简书](https://www.jianshu.com/p/453c6e7ff81c)

<font color="blue"> 2.2 如何保证消息队列的幂等性？</font>
幂等性定义：一个请求，不管重复来多少次，结果是不会改变的。
[参考](http://www.darylliu.cn/archives/43d339c7.html)

---

<font color="blue"> 3.RocketMQ为什么不采用Zookeeper而自己开发了NameServer? </font>

首先，RocketMQ 没用到ZK典型的选举场景。因为Master都是对等的。

ZooKeeper可以提供Master选举功能，比如Kafka用来给每个分区选一个broker作为leader
[推荐看此文](http://blog.csdn.net/chunlongyu/article/details/54018010)，但对于RocketMQ来说，**topic的数据在每个Master上是对等的，没有哪个Master上有topic上的全部数据**，所以这里选举leader没有意义；

其次，RockeqMQ集群中，需要有构件来处理一些通用数据，比如broker列表，broker刷新时间，虽然ZooKeeper也能存放数据，并有一致性保证，但处理数据之间的一些逻辑关系却比较麻烦，而且数据的逻辑解析操作得交给ZooKeeper客户端来做，如果有多种角色的客户端存在，自己解析多级数据确实是个麻烦事情；

既然RocketMQ集群中没有用到ZooKeeper的一些重量级的功能，只是使用ZooKeeper的数据一致性和发布订阅的话，与其依赖重量级的ZooKeeper，还不如写个轻量级的NameServer，NameServer也可以集群部署，NameServer与NameServer之间无任何信息同步，只有一千多行代码的NameServer稳定性肯定高于ZooKeeper，占用的系统资源也可以忽略不计，何乐而不为？

---

<font color="blue">  4.RocketMQ怎么处理**亿级消息的堆积的**？在保证了堆积亿级消息后，怎么保持**写入低延迟**？</font>

MQ的一个很重要的一个功能是挡住并缓冲数据洪峰，削峰填谷，从而保证后端系统的稳定性。因此RocketMQ的broker端需要具备一定的消息堆积能力（官方数据是支持亿级消息堆积）。

Broker在接收到消息后，会将其持久化到**本地磁盘**的文件中。

之所以没有选择持久化到远程DB或者KV数据库，个人认为可以减少网络开销，还可以避免因为带宽原因可能影响到消息的发送和消费的TPS。Broker通过使用Linux的**零拷贝技术**保证了提高了文件高并发读写。具体实现为：Broker通过Java的MappedByteBuffer(CommitLog, CQ等的源码都使用到了MappedByteBuffer)使用**mmap技术**, 将**文件直接映射到用户态的内存地址, Broker可以像操作内存一样操作文件** - 直接操作Linux操作系统的PageCache，这样就可以直接操作内存中的数据而不需要每次都通过IO去物理磁盘写文件。因此可以RocketMQ存储得以实现亿级消息堆积，并且保持了低写入延迟。

---
<font color="blue"> 5.RocketMQ消息订阅模式是什么？</font>

两种消息读取模式 ： Push or Pull。实际上，在RocketMQ中无论是Push还是Pull, **底层都是通过Consumer从Broker拉消息实现的**。为了做到能够实时接收消息，RocketMQ使用长轮询方式，保证消息实时性和Push方式一致。这种长轮询类似Web QQ收发消息机制。

<font color="blue"> 5.1.作为消费端，消息的推和拉有什么区别 </font>
Push最大的好处是实时, 有消息就立即发送。但是也有缺点：
1. 在Broker端需要维护Consumer的状态，不利于Broker去支持大量的Consumer的场景。
2. Consumer的消费速度是不一致的，由Broker进行推送难以处理不同的Consumer的状况。
3. Broker难以处理Consumer无法消费的情况，Broker无法去定Consumer的故障是暂时的还是永久的。
4. 大量的消息Push会加重Consumer的负载或者冲垮Consumer.

Pull解决了上述问题，状态维护在Consumer，所以Consumer可以很容易的根据自身的负载状态来决定Broker获取消息的频率。但是丢失了实时性。为了保证实时性，可以把拉取消息的间隔设置的短一点，但这也带来了一个另外一个问题，在没有消息的时候时候会有大量pull请求浪费CPU。为了做到能够实时接收消息，RocketMQ使用**长轮询方式。**

什么是长轮询方式？轮询是以固定间隔请求服务器，它不在乎这次请求是否能拉取到消息。而长轮询，在没有消息的时候，可以将请求阻塞在服务端延迟返回（会等待一会儿时间，然后将等待时间内的消息返回）。如果超时了，那么也返回空。有效的避免了无效的请求。

- 在Broker一直有可读消息的情况下，长轮询方式就等价于执行间隔为0的轮询pull模式（每次收到Pull结果就发起下一次Pull请求）。
- 在Broker没有可读消息的情况下，请求阻塞在Broker，在产生下一条消息或者请求超时之前响应请求给Consumer.

可以说长轮询结合了Push和Pull各自的优势，在Pull的基础上保证了实时性，实现也不会非常复杂

[RocketMQ长轮询源码实现](https://www.jianshu.com/p/c717cb26752e)
[Push or Pull](https://www.cnblogs.com/hzmark/p/mq_push_pull.html)

---

<font color="blue"> 6.RocketMQ对于负载均衡有哪些设计？</font>
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

<font color="blue"> 7.RocketMQ是怎么做消息失败重试机制的？</font>
消息重试分两种：Producer端重试和Consumer端重试。

生产端的消息失败，这种消息失败重试可以手动设置发送失败重试次数。
```java
producer.setRetryTimesWhenSendFailed(3);
```

消费端的话，Consumer消息消费有两种状态：
```java
public enum ConsumeConcurrentlyStatus {
    /**
     * 成功 Success consumption
     */
    CONSUME_SUCCESS,
    /**
     * 消费失败&稍后重试 Failure consumption,later try to consume
     */
    RECONSUME_LATER;
}
```
如果消息消费失败，只要返回ConsumeConcurrentlyStatus.RECONSUME_LATER，RocketMQ就会认为消息消费失败了，需要重新投递。

为了保证消息肯定至少被消费成功一次（AT LEAST ONCE），RocketMQ会把这批消息重发会Broker，在延迟的某个事件点（默认10s，业务可设）再次投递。而如果一直这样重复消费都持续失败到一定次数（默认16次），就会投递到死信队列（DLQ-Dead Letter Queue）。应用可以监控死信队列来做人工干预。

[参考](https://my.oschina.net/xinxingegeya/blog/1584617)

---

<font color="blue"> 8.RocketMQ是怎么设计事务机制的？</font>

分布式事务涉及到两阶段提交问题。RocketMQ通过offset方式实现分布式事务。RocketMQ把消息的发送分成了两个阶段：Prepare阶段和确认阶段。
（1） 发送Prepared消息
（2） updateDB
（3) 根据updateDB结果成功或者失败，确认或者取消Prepare消息。
如果前两步执行成功了，最后一步失败了。由于**RocketMQ会定期扫描所有的Prepared消息**，询问发送方，到底是要确认这条消息发出去了，还是取消这条消息。

[参考Travis‘s blog](https://blog.csdn.net/chunlongyu/article/details/53844393)

---
<font color="blue"> 9.RocketMQ是怎么“天然分布式的”？</font>

producer, consumer, broker, nameserver都可以分布式，集群部署，消除单点故障。

---
<font color="blue"> 10. RocketMQ怎么保证消息不丢失的？</font>
拆分为三个子问题：
- Producer如何保证消息不丢失的？
1. 生产阶段使用请求确认机制来保证消息的可靠传递。Broker收到消息后会给Producer发送一个确认响应。Producer收到响应后，完成了一次正常消息的发送。如果没有收到确认响应，Producer会自动重试。如果重试再失败，就会以返回值或者异常的方式告知用户。

2. 采取事务消息的投递方式，并不能保证消息100%成功投递成功到了Brocker，但是如果消息发送ACK失败了的话，此消息会存储到CommitLog当中，但是对ConsumeQueue是不可见的。可以在日志中查看这条异常消息，严格意义上讲，也并没有完全丢失。

3. RocketMQ 支持日志的索引，如果一条消息发送后超时，也可以通过查询日志API，来check是否在Brocker存储成功。

- Broker如何保证消息不丢失的？

1. 消息支持持久化到Commitlog里面，即使宕机后重启，未消费的消息也是可以加载出来的。

2. 对于单个节点的Broker，在收到消息后将消息写入磁盘后再给Producer返回确认响应，这样机制宕机，由于消息已经写入磁盘就不回丢失，恢复后还可以继续消费。也就是
同步刷盘、异步刷盘的策略。

3. 如果是 Broker 是由多个节点组成的集群，需要将 Broker 集群配置成：至少将消息发送到 2 个以上的节点，再给客户端回复发送确认响应。这样当某个 Broker 宕机时，其他的 Broker 可以替代宕机的 Broker，也不会发生消息丢失。

- Consumer如何保证消息不丢失的？

1. Consumer自身维护一个持久化的offset（对应MessageQueue里面的min offset），标记已经成功消费或者已经成功发回到broker的消息下标

2. 如果Consumer消费失败，那么它会把这个消息发回给Broker，发回成功后，再更新自己的offset

3. 如果Consumer消费失败，发回给broker时，broker挂掉了，那么Consumer会定时重试这个操作

4. 如果Consumer和broker一起挂了，消息也不会丢失，因为consumer 里面的offset是定时持久化的，重启之后，继续拉取offset之前的消息到本地

<font color="blue"> 11. RocketMQ相关事务消息和一致性实现？</font>
1.Producer在MQ上开启一个事务；
2.Producer给MQ发送一个半消息；
3.Producer执行本地事务，提交本地数据库事务；
4.1Producer本地数据库事务如果成功，则提交事务消息；Consumer才可见这个半消息。
4.2Producer本地数据库事务如果失败，则回滚事务消息。
5.为了避免Producer发送提交事务消息失败。RocketMQ 增加了事务反查机制，如果Broker没有收到提交或者回滚请求，Broker会定期去Producer上反查这个事务对应的本地事务状态，然后根据反查结果决定提交还是回滚这个事务。

半消息+反查。

<font color="blue"> 12. RocketMQ生产消息为什么只写在一个文件里？</font>
RocketMQ的消息是存储在一个单一的CommitLog文件里，从而避免在多topic多队列情况下磁盘的随机IO带来的性能消耗。

<font color="blue"> 12.1 随机读岂不是问题很大，怎么解决的。</font>
没有很好解决。
1.更多靠的是预读取，就是一次加载了很多数据到内存，被读到的概率也很大。
2.使用零拷贝，提升了消费消息时候从磁盘加载数据到内存的效率。

<font color="blue"> 13. RocketMQ对延迟队列的实现</font>
 RocketMQ发送延时消息时先把消息按照延迟时间段发送到指定的队列中(RocketMQ把每种延迟时间段的消息都存放到同一个队列中), 然后通过一个定时器进行轮询这些队列，查看消息是否到期，如果到期就把这个消息发送到指定topic的队列中，这样的好处是同一队列中的消息延时时间是一致的，还有一个好处是这个队列中的消息时按照消息到期时间进行递增排序的，说的简单直白就是队列中消息越靠前的到期时间越早。

---
总结系列文章：
1. {% post_link remoting RocketMQ源码分析1--Remoting %}
2. {% post_link nameserver RocketMQ源码分析2--NameServer %}
3. {% post_link rocketmq-store RocketMQ源码分析3--Store数据存储 %}
4. {% post_link rocketmq-broker RocketMQ源码分析4--Broker模块 %}
5. {% post_link client-consumer-md RocketMQ源码分析5--Client之Consumer模块 %}
6. {% post_link rocketmq-questions RocketMQ源码分析6--关于RocketMQ你想知道的Questions %}
---
[推荐jaskey文章总结][http://jaskey.github.io/blog/2016/12/19/rocketmq-rebalance/]
[refer1](https://www.jianshu.com/p/453c6e7ff81c)
[refer2](http://mp.weixin.qq.com/s/6PmcXJZVyWYZPssveeNkIw)
