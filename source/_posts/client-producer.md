---
title: client-producer
toc: false
banner: /images/
date: 2018-03-26 16:08:11
author:
tags:
---
本文是[RocketMQ源码分析系列](https://gsmtoday.github.io/tags/RocketMQ/)之六，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->
RocketMQ中Producer由用户部署，消息由Producer通过多种负载均衡模式发送到Broker集群，发送低延时，支持failfast.