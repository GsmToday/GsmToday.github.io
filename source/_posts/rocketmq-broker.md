---
title: RocketMQ源码分析4--Broker模块
toc: true
banner: /images/bird1.png
date:  2018-03-26 15:48:57
author: GSM
tags:
  - RocketMQ
categories: 中间件
---
本文是[RocketMQ源码分析系列](https://gsmtoday.github.io/tags/RocketMQ/)之四，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->
Broker模块是RocketMQ的核心组件，消息中转角色：负责消息存储和消息转发，和Producer对接 - 接收Producer发送的消息并转存（调用store模块持久化到磁盘）；和Consumer对接 - 消息订阅拉消息; 
另外Broker解决了消息堆积，并通过Master-Slave横向扩展实现了HA。

<img src="https://rocketmq.apache.org/assets/images/rmq-basic-arc.png" alt="RocketMQ Architecture" title="RocketMQ Architecture" width="800" height="800" />

对于RocketMQ，Broker是逻辑概念。一台机器或者为Master或者为Slave的一个实例。
```
One Broker = One Master + n * Slaves
```
一个Master可以对应多个Slave, Master与Slave的对应关系通过指定相同的BrokerName关联起来，BrokerId=0的实例为Master,非0的实例为Slave。在横向扩展情况下，Master可以部署为多实例。

每个Broker与NameServer集群中的所有节点建立长连接 - 每个Broker每隔30s向NameServer更新自身Topic和Broker路由信息.
```java
  this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {
            @Override
            public void run() {
                try {
                    BrokerController.this.registerBrokerAll(true, false);
                }
                catch (Exception e) {
                    log.error("registerBrokerAll Exception", e);
                }
            }
        }, 1000 * 10, 1000 * 30, TimeUnit.MILLISECONDS);
```

## start 启动
Broker启动的时候主要启动一些辅助线程服务，例如CQ和CommitLog的刷盘线程服务，启动用于构建indexfile和CQ的服务的ReputService服务，启动BrokerOutAPI(Broker和其他模块通信类), 并创建消息发送线程池，消息拉取线程池，admin管理线程池和client管理线程池。以及把broker注册到NameServer等等。另外Broker启动的时候还将已经持久化到硬盘的topic,，consumerOffset， subscriptionGroup, consumerFilter到内存。

另外Broker启动的时候还会注册Netty的处理器(BrokerController.initialize)，用于和NameServer之间通信的处理。注册Processor会为每个消息的注册码指定一个请求处理器。例如负责处理生产者发送消息时，NameServer与Broker通信的处理器`SendMessageProcessor`, 负责处理消费者消费消息时，NameServer与Broker通信的处理器`PullMessageProcessor`等等。

参见代码：
```java
public class BrokerStartup {
    public static Properties properties = null;
    public static CommandLine commandLine = null;
    public static String configFile = null;
    public static Logger log;

    public static void main(String[] args) {
        start(createBrokerController(args));
    }
    ...
}
```

## 消息的发送
当消息的生产者向Broker发送消息时候，实际上消息先到达NameServer, NameServer将消息发送给Broker进行消息的落地。

这里引用[kyghkgyh](https://kgyhkgyh.gitbooks.io/rocketmq/content/chapter2.html)的broker接收消息的图：
<img src="broker-receive.png" width = "600" height = "400" align=center />

Broker通过提供SendMessageProcessor与NameServer进行通信获取消息，并调用[store](https://gsmtoday.github.io/2018/03/11/rocketmq-store/)模块提供的写commitLog的接口，将消息持久化到commitlog文件，最后落地到磁盘上。

## Broker与Topic的关系
对于消息来说，topic是消息的逻辑分类单元，queue是消息的物理存储单元。一个topic下可以有多个queue。 
逻辑上：当生产者生产消息时候需要为消息指定topic，topic创建时需要指定1个或者多个broker。topic与broker是多对多的关系，一个topic分布在多个broker上，一个broker可以配置多个topic. 
物理上：上缠着生产消息发送给broker时候需要指定发送到哪个queue上。默认情况生产者会轮询将消息发送到每个queue，顺序随机。

NameServer就是通过broker与topic的映射关系来做路由。


## 消息的堆积
MQ的一个很重要的一个功能是挡住并缓冲数据洪峰，削峰填谷，从而保证后端系统的稳定性。因此RocketMQ的broker端需要具备一定的消息堆积能力（官方数据是支持亿级消息堆积）。

Broker在接收到消息后，会将其持久化到本地磁盘的文件中。之所以没有选择持久化到远程DB或者KV数据库，个人认为可以减少网络开销，还可以避免因为带宽原因可能影响到消息的发送和消费的TPS。Broker通过使用Linux的**零拷贝技术**保证了提高了文件高并发读写。具体实现为：Broker通过Java的MappedByteBuffer(CommitLog, CQ等的源码都使用到了MappedByteBuffer)使用**mmap技术**, 将文件直接映射到用户态的内存地址, Broker可以像操作内存一样操作文件 - 直接操作Linux操作系统的PageCache，这样就可以直接操作内存中的数据而不需要每次都通过IO去物理磁盘写文件。因此可以RocketMQ存储得以实现亿级消息堆积，并且保持了低写入延迟。

## Broker响应Consumer请求 - 消息的接收
<img src="consumer1.png" align=center />
关于RocketMQ的两种消费模式Push与Pull，具体[参见]()。

RocketMQ在具体实现时，Push和Pull模式都是采用消费者主动Pull的方式 - Consumer长轮询从broker拉取消息。这样可以保证在消息不堆积情况下，消息到达Broker后，能立刻到达Consumer - Consumer先根据对应的Topic+queueId去ConsumeQueue拿到该消息在CommitLog中的offset, 接着通过offset到CommitLog中拿到具体消息。这样实现了消息的**实时性**不低于Push. 

BrokerController启动时候，会通过initialize()注册PullMessageProcessor来处理拉消息的请求。
BrokerControler 
```java
    public void registerProcessor() {
        ...
        /**
         * PullMessageProcessor
         */
        this.remotingServer.registerProcessor(RequestCode.PULL_MESSAGE, this.pullMessageProcessor, this.pullMessageExecutor);
        this.pullMessageProcessor.registerConsumeMessageHook(consumeMessageHookList);
        ...
    }
```

PullMessageProcessor处理拉消息请求的逻辑：
```java
private RemotingCommand processRequest(final Channel channel, RemotingCommand request, boolean brokerAllowSuspend){
    ...
    final GetMessageResult getMessageResult =
            this.brokerController.getMessageStore().getMessage(requestHeader.getConsumerGroup(), requestHeader.getTopic(),
                requestHeader.getQueueId(), requestHeader.getQueueOffset(), requestHeader.getMaxMsgNums(), messageFilter);
    ...
}

```
类似于Producer发送消息，PullMessageProcessor解析（用户 -》 NameServer -》Broker）消息，调用store模块的DefaultMessageStore提供的方法, 从topic的某个CQ指定offset开始拉消息，一次最多maxMagNums条，并且使用指定的订阅表达式进行过滤。

```java
GetMessageResult getMessage(final String group, final String topic, final int queueId, final long offset, final int maxMsgNums, final MessageFilter messageFilter) {
    ....
}
```
<img src="pullmessg.svg" alt="Broker对拉到的消息处理流程" title="Broker对拉到的消息处理流程" align=center />

### Broker 消息过滤
RocketMQ是在订阅时做过滤(PullMessageProcessor - DefaultMessageStore.getMessage() - ExpressionMessageFilter)。
```java
public boolean isMatchedByConsumeQueue(Long tagsCode, ConsumeQueueExt.CqExtUnit cqExtUnit) 
```
(1). 在 Broker 端进行 Message Tag 比对，先遍历 Consume Queue，如果存储的 Message Tag 与订阅的 Message Tag 不符合，则跳过，继续比对下一个，符合则传输给 Consumer。注意:Message Tag 是字符串形式，Consume Queue 中存储的是其对应的 hashcode，比对时也是比对 hashcode。
(2). Consumer 收到过滤后的消息后，同样也要执行在 Broker 端的操作，但是比对的是真实的 Message Tag 字符串，而不是 Hashcode。

为什么过滤要这样做?
(1). Message Tag 存储 Hashcode，是为了在 Consume Queue 定长方式存储，节约空间。
(2). 过滤过程中不会访问 Commit Log 数据，可以保证堆积情况下也能高效过滤。
(3). 即使存在Hash冲突，也可以在Consumer端进行修正，保证万无一失。

## Broker 处理消息重复 ： At least Once or Exactly Only Once
[引自官方Doc: RocketMQ 原理简介]
- At least Once: 是指每个消息必须投递一次。RocketMQ Consumer 先 pull 消息到本地，消费完成后，才向服务器返回 ack，如果没有消费一定不会 ack 消息，所以 RocketMQ 可以很好的支持此特性。
- Exactly Only Once
(1). 发送消息阶段，不允许发送重复的消息。
(2). 消费消息阶段，不允许消费重复的消息。
只有以上两个条件都满足情况下，才能认为消息是“Exactly Only Once”，而要实现以上两点，在分布式系统环境下，不可避免要产生巨大的开销。所以 RocketMQ 为了追求高性能，并不保证此特性，要求**在业务上进行去重**，也就是说消费消息要做到幂等性。RocketMQ 虽然不能严格保证不重复，但是正常情况下很少会出现重复发送、消费情况，只有网络异常，Consumer启停等异常情况下会出现消息重复。

此问题的本质原因是网络调用存在不确定性，即既不成功也不失败的第三种状态，所以才产生了消息重复性问 题。

## Broker 和Name Server的心跳实现
Broker启动时,会在定时线程池中每30秒注册信息至Name Server

```java
  this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {

            @Override
            public void run() {
                try {
                    BrokerController.this.registerBrokerAll(true, false);
                } catch (Throwable e) {
                    log.error("registerBrokerAll Exception", e);
                }
            }
        }, 1000 * 10, 1000 * 30, TimeUnit.MILLISECONDS);
```

## Broker 的主从同步
BrokerController在启动的时候，会通过initialize()判断Broker的角色，如果角色是Slave的话，会启动一个定时线程任务，每隔60s调用SlaveSynchronize.syncAll()进行主从同步:
1. Topic配置同步
2. 消费进度信息同步
3. 延迟消费进度信息同步
4. 订阅关系同步

如果角色是Master的话，打印主备之间commitlog同步位点差异。

```java
 if (BrokerRole.SLAVE == this.messageStoreConfig.getBrokerRole()) {
                if (this.messageStoreConfig.getHaMasterAddress() != null && this.messageStoreConfig.getHaMasterAddress().length() >= 6) {
                    this.messageStore.updateHaMasterAddress(this.messageStoreConfig.getHaMasterAddress());
                    this.updateMasterHAServerAddrPeriodically = false;
                } else {
                    this.updateMasterHAServerAddrPeriodically = true;
                }

                this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {

                    @Override
                    public void run() {
                        try {
                            BrokerController.this.slaveSynchronize.syncAll();
                        } catch (Throwable e) {
                            log.error("ScheduledTask syncAll slave exception", e);
                        }
                    }
                }, 1000 * 10, 1000 * 60, TimeUnit.MILLISECONDS);
            } else {
                this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {

                    @Override
                    public void run() {
                        try {
                            BrokerController.this.printMasterAndSlaveDiff();
                        } catch (Throwable e) {
                            log.error("schedule printMasterAndSlaveDiff error.", e);
                        }
                    }
                }, 1000 * 10, 1000 * 60, TimeUnit.MILLISECONDS);
            }
```

```java
    public void syncAll() {
        this.syncTopicConfig(); // Topic配置同步 - 同步topic.json文件
        this.syncConsumerOffset(); // 消费进度信息同步 - 同步consumerOffset.json文件
        this.syncDelayOffset(); // 延迟消费进度信息同步 - 同步delayOffset.json文件
        this.syncSubscriptionGroupConfig(); // 订阅关系同步 - 同步subscriptionGroup.json文件
    }
```

<img src="brokerha.png" align=center />

# 参考
1. https://rocketmq.apache.org/docs/rmq-arc/
2. 实际问题解决 -http://dbaplus.cn/news-21-1123-1.html
3. [RocketMQ-HA高可用,作者meilong_whpu](https://blog.csdn.net/meilong_whpu/article/details/76922456)
4. [Linux 内核的文件 Cache 管理机制介绍](https://www.ibm.com/developerworks/cn/linux/l-cache/index.html)

