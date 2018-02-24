---
title: RocketMQ源码分析2--NameServer
toc: true
banner: /images/stingray.jpg
date: 2018-02-23 19:25:00
author: GSM
tags:
  - RocketMQ
categories: 消息队列
---

本文是[RocketMQ源码分析系列](http://localhost:4000/tags/RocketMQ/)之二，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->

NameServer是类似于Zookeeper的分布式服务治理可单独部署的模块。主要负责管理集群的路由信息，包括Topic队列信息和Broker地址信息。

先来讲讲什么是分布式系统的<font color = "blue">服务治理</font>？

服务治理在分布式系统的构建中是类似血液一样的存在。随着分布式系统服务的越来越多，而每个服务都可以横向扩展出多个机器，因此服务的各种状况都可能出现。服务可能出现某台机器宕机，如果用户的请求刚好打到宕机的机器，就会造成服务不可用；当提供服务的机器发生变化，也需要将机器的调用IP通知服务的调用方。另外当服务的主机有多台的时候，如何负载均衡地分发请求也是需要考虑的。

服务治理具体为服务注册和服务发现。它作为一个管理中心一样的存在，解耦provider和consumer，需要分布式强一致性的存储服务的IP地址以及端口。目前业界常见的产品为Zookeeper，Zookeeper使用Paxos保证强一致性。

在同一个分布式集群中的进程或服务，互相感知并建立连接，这就是服务发现。服务发现最明显的优点就是零配置，不用使用硬编码的网络地址，<font color = "red">只需服务的名字，就能使用服务</font>。在现代体系架构中，单个服务实力的启动和销毁很常见，所以应该做到无需了解整个架构的部署拓扑，就能找到整个实例。复杂的服务发现组件要提供更多的功能，例如服务元数据存储，监控监控，多种查询和实时更新等。

在服务治理之前，RPC调用使用点对点方式，完全通过人为进行配置操作决定，运维成本高且容易出错，且整个系统运行期间的服务稳定性也无法很好感知。因此需要设计出包含基本功能服务的自动注册，客户端的自动发现，变更下发的服务治理。

## NameServer作用
当多Broker Master部署时，Master之间是不需要知道彼此的，这样的设计降低了Broker实现的复杂性。这样在分布式环境下，某台Master宕机或上线，不会对其他Master造成任何影响。那么怎样才能知道网络中有多少台Master和Slave？

**NameServer作用1**: Broker在启动的时候会去NameServer注册，Nameserver会维护Broker的状态和地址。

**NameServer作用2**：Nameserver还维护了一份Topic和Topic对应队列的地址列表，broker每次发送心跳过来的时候都会把Topic信息带上。客户端依靠Nameserver决定去获取对应topic的路由信息，从而决定对那些Broker做连接。

**NameServer作用3**：接收Producer和Consumer的请求，根据某个topic获取到对应的broker的路由信息，即实现服务发现功能。

**Nameserver作用4**：用来保存所有broker的Filter列表。


## Nameserver启动
NameServer的启动主要是初始化一个通信组件中的NettyRemotingServer实例，用来进行网络通信。另外NameServer还启动定时任务，用于broker存活检测。

<img src="nameservercontroller.png" width = "500" height = "400" align=center />
RouteInfoManager 是NameServer核心类，它管理broker的路由信息，topic队列信息。其数据结构如下：

```java
    RouteInfo{
    ...
    private final HashMap<String/* topic */, List<QueueData>> topicQueueTable; // topic队列表，存储每个topic包含的队列数据
    private final HashMap<String/* brokerName */, BrokerData> brokerAddrTable; // broker的地址表
    private final HashMap<String/* clusterName */, Set<String/* brokerName */>> clusterAddrTable;//集群主备信息表
    private final HashMap<String/* brokerAddr */, BrokerLiveInfo> brokerLiveTable; // BrokerLiveInfo 存储了broker的版本号，channel以及最近心跳时间等信息
    private final HashMap<String/* brokerAddr */, List<String>/* Filter Server */> filterServerTable; // 记录了每个broker的filter信息
    ...
}
```

NameServer初始化步骤：

<img src="nameserver_ini.png" width = "500" height = "400" align=center />
## 路由信息的管理（Topic & Broker）

Broker启动时候/topic配置变更/每隔30s（Broker启动时候的定时任务），broker会发起register到namserver的动作，把broker
自己的基础数据以及维护的topic 一起提交给nameserver进行管理，同时把broker注册到NameServer 这些信息最后组成RouteInfo路由信息，由生产者和消费者来使用。

```java
RegisterBrokerResult registerBrokerResult = this.brokerOuterAPI.registerBrokerAll(//
    this.brokerConfig.getBrokerClusterName(), //
    this.getBrokerAddr(), //broker地址
    this.brokerConfig.getBrokerName(), //broker名称
    this.brokerConfig.getBrokerId(), //broker id
    this.getHAServerAddr(), //
    topicConfigWrapper,//所有topic
    this.filterServerManager.buildNewFilterServerList(),//
    oneway);
```

## 心跳检查

NameServer启动初始化过程，会异步启动定时任务线程，定时跑2个任务，监听broker的存活情况。
第一个：每隔10分钟扫描出不活动的broker,然后从routeinfo删除并关闭broker和nameserver通信的channel。
第二个：每隔10分钟定时打印configTable的信息

```java
this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {

    @Override
    public void run() {
        NamesrvController.this.routeInfoManager.scanNotActiveBroker();
    }
}, 5, 10, TimeUnit.SECONDS);
```

```java
this.scheduledExecutorService.scheduleAtFixedRate(new Runnable() {

    @Override
    public void run() {
        NamesrvController.this.kvConfigManager.printAllPeriodically();
    }
}, 1, 10, TimeUnit.MINUTES);
```

通过定时扫描操作实现了服务治理中，如果出现机器宕机，可以自动摘除挂掉的机器，仍然保证服务可用。

## 服务发现
接收Producer和Consumer的请求，根据某个topic获取到对应的broker的路由信息，即实现服务发现功能
当Broker收到Producer发送的消息并判断
```
RequestCode = GET_ROUTINEINFO_BY_TOPIC
```
之后，会调用默认注册的请求处理器（DefaultRequestProcessor）的getRouteInfoByTopic方法，该方法根据Topic获取对应的broker路由信息. 
```java
TopicRouteData topicRouteData = this.namesrvController.getRouteInfoManager().pickupTopicRouteData(requestHeader.getTopic());
```
pickupTopicRouteData关于获取Topic BrokerRouteInfo核心代码：
```java
...
this.lock.readLock().lockInterruptibly();

List<QueueData> queueDataList = this.topicQueueTable.get(topic);
if (queueDataList != null) {
    topicRouteData.setQueueDatas(queueDataList);
...
}
this.lock.readLock().unlock();
```

具体代码流程如下：
RouteInfoMananger的topicQueueTable记录了topic名称与broker队列[broker名称]的映射关系，而brokerAddrTable记录了brokerName与broker地址的映射关系，因此基于topicQueueTable和brokerAddrTable这两个关键属性即可以根据topic获取对应的broker路由地址。

## 另一个角度看NameServer

通过看源码NameServer一共有8类线程：

|线程名称|作用|核心方法|
|:-:|:-:|:-:|
|ServerHouseKeepingService:type Timer||| 
|NSScheduledThread1:type scheduledExecutorService|定时任务线程，定时跑2个任务。监听broker的存活 第一个：每隔10分钟扫描出不活动的broker,然后从routeinfo删除 第二个：每隔10分钟定时打印configTable的信息|第一个：scanNotActiveBroker 每10秒扫描一次brokerLiveTable.怎么判断broker是不活动的呢？brokerLiveInfo上次发送过来【注册broker】的更新时间(lastUpdateTimestamp)+设置的broker超时时间 < 系统当前时间，则说明此broker不活动了。第二个：每隔10秒日志打印KVConfig.
|EventLoopGroupBoss:type EventLoopGroup|Netty的boss线程（accept线程)，负责处理客户端的TCP连接请求。||
|EventLoopGroupSelector:type EventLoopGroup|Netty的worker线程 是真正负责I/O读写操作的线程组。通过ServerBootstrap的group方法进行设置，用于后续的channel绑定||
|NettyEventExecuter|一个单独的线程，监听NettyChannel状态变化通知ChannelEventListener做出响应的动作||
|defaultEventExecutorGroup|Netty编解码||
|NettyServerPublicExecutor|MQ消息根据RequestCode被分成了很多种类，每一个种类都对应一个处理器。每个处理器在处理消息时候需要在一个独立的线程池里执行 (线程模型问题，可能消息处理会设计比较复杂的操作，不适合放在与channel绑定的单线程里操作，防止阻塞)。如果调用方没有提供，就使用remotingserver自带的这个线程池。||
|RemotingExecutorThread_|Nameserver自己的processor在此线程池里执行||

## 快速问答
- **NameServer怎么知道有多少broker机器？**
RouteInfoManager 有一个brokerLiveInfo列表保存当前存货的broker机器，可以从这里get到。

- **为什么不用Zookeeper而自己开发了一个NameServer?**
[引用自](http://blog.csdn.net/earthhour/article/details/78718064)首先，ZooKeeper可以提供Master选举功能，比如Kafka用来给每个分区选一个broker作为leader，但对于RocketMQ来说，**topic的数据在每个Master上是对等的，没有哪个Master上有topic上的全部数据**，所以这里选举leader没有意义；

其次，RockeqMQ集群中，需要有构件来处理一些通用数据，比如broker列表，broker刷新时间，虽然ZooKeeper也能存放数据，并有一致性保证，但处理数据之间的一些逻辑关系却比较麻烦，而且数据的逻辑解析操作得交给ZooKeeper客户端来做，如果有多种角色的客户端存在，自己解析多级数据确实是个麻烦事情；

既然RocketMQ集群中没有用到ZooKeeper的一些重量级的功能，只是使用ZooKeeper的数据一致性和发布订阅的话，与其依赖重量级的ZooKeeper，还不如写个轻量级的NameServer，NameServer也可以集群部署，NameServer与NameServer之间无任何信息同步，只有一千多行代码的NameServer稳定性肯定高于ZooKeeper，占用的系统资源也可以忽略不计，何乐而不为？
## 参考
1. https://www.jianshu.com/p/3e025cf69a6a
2. http://blog.csdn.net/earthhour/article/details/78718064