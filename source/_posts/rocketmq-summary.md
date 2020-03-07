---
title: RocketMQ学习系列
toc: true
date: 2018-02-18 14:25:47
author: GSM 
tags:
  - RocketMQ
categories: 学习积累
---
RocketMQ学习系列。
<!--more-->

<img src="what-is-rocketmq.png" width = "600" height = "400" alt="什么是RocketMQ" align=center />
引自官方文档，RocketMQ是：
- 是一个队列模型的消息中间件，具有高性能、高可靠、高实时、分布式特点。
- Producer、Consumer、队列都可以分布式。
- Producer 向一些队列轮流发送消息，队列集合称为 Topic，Consumer 如果做广播消费，则一个 consumer实例消费这个 Topic 对应的所有队列；如果做集群消费，则多个 Consumer 实例平均消费这个 topic 对应的队列集合。
- 能够保证严格的消息顺序
- 提供丰富的消息拉取模式
- 实时的消息订阅机制
- 高效的订阅者水平扩展能力
- 亿级消息堆积能力
- 较少的依赖

物理部署结构：
<img src="archi.png" width = "600" height = "400" alt="RocketMQ物理部署图" align=center />

RocketMQ 网络部署特点
- NameServer 是一个几乎无状态节点，可集群部署，节点之间无任何信息同步。
- Broker 部署相对复杂，Broker 分为 Master 与 Slave，一个 Master 可以对应多个 Slave，但是一个 Slave 只能对应一个 Master，Master 与 Slave 的对应关系通过指定相同的 BrokerName，不同的 BrokerId 来定义，BrokerId 为 0 表示 Master，非 0 表示 Slave。Master 也可以部署多个。每个 Broker 与 Name Server 集群中的所有节点建立长连接，定时注册 Topic 信息到所有 Name Server。
- Producer 与 NameServer 集群中的其中一个节点(随机选择)建立长连接，定期从 NameServer 取 Topic 路由信息，并向提供 Topic 服务的 Master 建立长连接，且定时向 Master 发送心跳。Producer 完全无状态，可集群部署。
- Consumer 与 NameServer 集群中的其中一个节点(随机选择)建立长连接，定期从 NameServer 取 Topic 路由信息，并向提供 Topic 服务的 Master、Slave 建立长连接，且定时向 Master、Slave 发送心跳。Consumer 既可以从 Master 订阅消息，也可以从 Slave 订阅消息，订阅规则由 Broker 配置决定。

以下是阅读源码时候的总结系列文章：
1. {% post_link remoting RocketMQ源码分析1--Remoting %}
2. {% post_link nameserver RocketMQ源码分析2--NameServer %}
3. {% post_link rocketmq-store RocketMQ源码分析3--Store数据存储 %}
4. {% post_link rocketmq-broker RocketMQ源码分析4--Broker模块 %}
5. {% post_link client-consumer-md RocketMQ源码分析5--Client之Consumer模块 %}
6. {% post_link rocketmq-questions RocketMQ源码分析6--关于RocketMQ你想知道的Questions %}