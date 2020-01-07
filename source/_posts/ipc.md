---
title: 一种进程间通信的方案与实现
toc: true
date: 2020-01-07 16:10:13
author: NX
tags:
    - optimize
categories: 业务实践
---

# 背景

在外化重构过程中，Python包的功能迁移到了Java服务端实现，而部分三方依赖，用Java语言重写开销过大，所以需要某种方式通过Java程序调用本地Python进程，执行用户请求并完成响应。

<!-- more -->

前期的实现方式为基于apache的exec包，每次用户请求，调起一个Python进程，完成用户请求。在压测过程中发现，当发压机生成的请求过多之后，会引发Linux操作系统的OOM机制，主动kill掉一些python进程甚至杀死Java的服务进程，QPS过低且存在服务崩溃的风险。

# 改造思路

本次改造主要解决的问题在于提高系统吞吐量，并规避Linux OOM的问题，保护Java的服务进程。首先为每个请求创建一个Python进程的本身开销就很大，其次当遇到一些需要处理图片等内存占用较高的Python进程，请求量大了之后就极容易触发Linux的OOM kill机制。

所以本次改造的着手点在于：

1. 固定Python进程数目，采用基于内存映射的方式，完成Java进程和Python进程间的通信
2. 引入请求的排队和超时机制，在流量突发的情况下，使得服务程序也能够平滑稳定的执行用户请求

# 实现要点

1. Spring的异步请求；基于DeferredResult将用户请求异步化，避免因为执行某些耗时较长的python方法阻塞Spring执行用户请求的核心线程
2. 用户请求的排队，reject以及负载均衡机制
3. 基于内存映射的进程间通信，需要解决请求响应的匹配识别，通信消息的编解码方式以及映射文件的无锁化访问
4. Python侧程序的改造

# 请求处理模型

初始方案以每个独立的python进程为核心，构造一套闭环的执行Loop。

<img src="request-loop.png" width = "600" height = "400" title="request-loop" />

其中，每个用户请求会首先放入一个Blocking queue中，等待处理，如果队列满了，请求被直接拒绝。Pthread负责从直接关联的queue里取请求，通过mapped file通知python进程处理用户请求，python读取并执行后通过另外一个mapped file将结果发送给接收线程Cthread，由Cthread完成包装后，返回给用户。此处，之所以创建独立的Cthread来处理结果，是由于针对python执行结果的可能会比较耗时，比如会写图片到OSS这种操作，有利于提高吞吐量。

在第一版的方案实现中存在一个问题就是：同一个Loop的Pthread需要等到Cthread回写结果完成后，才能继续处理下一个请求，（二者依赖信号量同步）其实在Cthread从mapped file取出处理结果后，Pthread就可以继续处理下一个请求，而无需等待Cthread的业务逻辑处理。所以，把Cthread的功能进一步拆解为两个部分：读mapped file 和 响应结果处理，并将读mapped file的逻辑上推至Pthread中，以线程池的方式执行响应结果处理，进一步提高并发程度，并且减少了一份 mmap file的使用。

改进方案：

<img src="request-loop-final.png" width = "600" height = "400" title="request-loop-final" />

请求与响应的读写都由pthread控制， 减少mapped file文件的数量。引入线程池，独立执行响应的处理，做到更强的异步化处理。

# 压测结果

以ybc_table为例，改造前10thread， 20s的压测结果如下

```c
`> ---- Global Information -------------------------------------------------------- 
> request count                                      14140 (OK=424    KO=13716 ) 
> min response time                                      1 (OK=53     KO=1     ) 
> max response time                                    426 (OK=426    KO=100   ) 
> mean response time                                    13 (OK=238    KO=7     ) 
> std deviation                                         42 (OK=62     KO=10    ) 
> response time 50th percentile                          6 (OK=250    KO=6     ) 
> response time 75th percentile                          8 (OK=274    KO=8     ) 
> response time 95th percentile                         50 (OK=332    KO=18    ) 
> response time 99th percentile                        260 (OK=385    KO=57    ) 
> mean requests/sec                                673.333 (OK=20.19  KO=653.143) 
---- Response Time Distribution ------------------------------------------------ 
> t < 800 ms                                           424 (  3%) 
> 800 ms < t < 1200 ms                                   0 (  0%) 
> t > 1200 ms                                            0 (  0%) 
> failed                                             13716 ( 97%) 
---- Errors -------------------------------------------------------------------- 
> status.find.in(200,304,201,202,203,204,205,206,207,208,209), b  13716 (100.0%) ut actually found 500
```

改造后，10个独立的python进程，100thread， 60s的压测结果如下，吞吐量和响应时间都有显著提升

```c
---- Global Information -------------------------------------------------------- 
> request count                                      53235 (OK=53232  KO=3     ) 
> min response time                                      1 (OK=1      KO=3674  ) 
> max response time                                   4434 (OK=3913   KO=4434  ) 
> mean response time                                   112 (OK=112    KO=3954  ) 
> std deviation                                        211 (OK=209    KO=340   ) 
> response time 50th percentile                         13 (OK=13     KO=3756  ) 
> response time 75th percentile                        153 (OK=153    KO=4095  ) 
> response time 95th percentile                        481 (OK=481    KO=4366  ) 
> response time 99th percentile                        771 (OK=769    KO=4420  ) 
> mean requests/sec                                858.629 (OK=858.581 KO=0.048 ) 
---- Response Time Distribution ------------------------------------------------ 
> t < 800 ms                                         52761 ( 99%) 
> 800 ms < t < 1200 ms                                 324 (  1%) 
> t > 1200 ms                                          147 (  0%) 
> failed                                                 3 (  0%) 
---- Errors -------------------------------------------------------------------- 
> status.find.in(200,304,201,202,203,204,205,206,207,208,209),3 (100.0%) ut actually found 500 
```