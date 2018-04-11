---
title: RocketMQ源码分析7--Questions
toc: true
banner: /images/lion.jpeg
date: 2018-04-31 10:34:51
author: GSM
tags:
  - RocketMQ
categories: 消息队列
---
既见树木，又见森林。
<!-- more -->
1. RocketMQ如何保证**严格的消息顺序**？
**顺序消息**是RocketMQ功能特性上的一个卖点。RocketMQ可以实现全局保序。需要重点说一下，这里的全局是有前提，针对某个唯一标识（能够被Hash成唯一标识），比方说大卖家账号，某类产品的订单等。其技术实现原理也相对比较简单，保证对通道的单一实例操作，如单进程、单线程写，单进程、线程读。
2. RocketMQ为什么不采用Zookeeper而自己开发了NameServer?
3. RocketMQ怎么处理**亿级消息的堆积的**？在保证了堆积亿级消息后，怎么保持**写入低延迟**？
4. RocketMQ消息**订阅模式**是什么？
两种消息读取模式 ： Push or Pull。
具体实现时候Push和Pull模式都是采用消费者主动Pull的房还是，即consumer轮训从broker拉取消息。
Push:
Pull:消费者主动的调用拉消息方法从Broker获取消息，Note: **消费位置需要记录，以防止出现消费重复消费。**
[](https://my.oschina.net/xinxingegeya/blog/956370)
5. RocketMQ对于负载均衡有哪些设计？
Producer/Consumer Group. 通过Group机制，RocketMQ天然的支持消息负载均衡。
http://jaskey.github.io/blog/2016/12/19/rocketmq-rebalance/
6. RocketMQ是怎么做**消息失败重试机制**的？
7. RocketMQ是怎么设计事务机制的？
事务消息是指可以用来实现最终一致性的分布式事务。
8. RocketMQ是怎么“天然分布式的”？
producer, consumer, broker, nameserver都可以分布式，集群部署，消除单点故障。

https://www.jianshu.com/p/453c6e7ff81c

http://mp.weixin.qq.com/s/6PmcXJZVyWYZPssveeNkIw