---
title: 一次Kafka消费不到数据的踩坑记录
toc: true
thumbnail: /images/pollor bear.jpg
date: 2019-11-24 13:55:20
author: GSM
tags: Kafka
categories: 业务实践
---
突然就..kafka消费不到数据了...
<!-- more -->
问题从发生到验证再到解决比较曲折复杂，下文呈现的是事后梳理过的故障解决全貌。

# 故障
大概在昨天下午2点多，kafka突然消费不到数据。表现为：
1. java服务不再打印消费日志，业务不再有新数据的处理；
2. java服务重启后立刻消费几批数据，但是很快就会不再消费（拉到的数据size 为0），异常如下截图：
<img src="problem1.png" width = "1000" height = "800" align=center title="attempt to heart beat failed since the group is rebalancing"/>

This member will leave the group because consumer poll timeout has expired. This means the time between subsequent calls to poll() was longer than the configured max.poll.interval.ms, which typically implies that the poll loop is spending too much time processing messages. You can address this either by increasing max.poll.interval.ms or by reducing the maximum size of batches returned in poll() with max.poll.records.

<img src="problem2.png" width = "800" height = "600" align=center />

<img src="problem3.jpeg" width = "800" height = "600" align=center />

当时被kafka-version properties：null问题迷惑，以为是客户端使用的公司kafka-client有问题，改用kafka原生client后，不再有kafka-version properties：null问题，但是仍然消费不到数据。

# 解决
问题的解决是源自厂有一老（如有一宝）的同事的一句提醒，方才从怀疑kafka-client，转变方向到解决poll超时问题。
<img src="tips.png" width = "800" height = "600" align=center />

Kafka `max.poll.interval.ms`: 它表示最大的poll数据间隔. 如果超过这个间隔没有发起pool请求，但heartbeat仍旧在发，就认为该consumer处于 livelock状态。就会将该consumer退出consumer group。Consumer Coordinator会让消费者离开消费组，并处罚新一轮的rebalance. 

所以为了不使Consumer 自己被退出，Consumer 应该不停的发起poll(timeout)操作。而这个动作 KafkaConsumer Client是不会帮我们做的，这就需要自己在程序中不停的调用poll方法了。

通过查wiki公司默认配置：
max.poll.interval.ms = 300000(默认间隔时间为300s)
max.poll.records = 500









