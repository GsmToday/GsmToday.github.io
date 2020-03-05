---
title: Netty 是怎么做内存管理--内存池
toc: false
thumbnail: /images/shark.jpg
date: 2017-09-03 12:22:46
author: NX
tags:
  - Netty
categories: 学习积累
---
内存管理的主要目的是合理分配内存，减少内存碎片，及时回收资源，提高内存使用效率。（任何一个组件管理内存的目的都是这个）。
<!--more-->

从Netty层面来说，操作系统分配内存容易有碎页并且比较耗时，一次性申请足够空间，自己管理更高效。Netty内存管理其实质就是先分配一块大内存，然后在内存的分配和回收过程中，使用一些数据结构记录内存使用状态，如果有新的分配请求，根据这些状态信息寻找最合适的位置并更新内存结构。释放内存时候：同步修改数据结构.

## Netty 是怎么做内存管理--内存池
> Netty is a NIO client server framework which enables quick and easy development of network applications such as protocol servers and clients. It greatly simplifies and streamlines network programming such as TCP and UDP socket server.  

个人以为Netty之所以优秀的关键词可以概括为以下两点：
+ 方便：良好的封装与接口设计，对多种通信协议的支持，使得上手简单，快速
+ 高效（性能）：异步的、事件驱动的线程模型和高效的内存管理机制

作为服务端的开发人员，有必要深入学习一下其内部原理。话不多说，先从内存池开始。
<!-- more -->

Netty内存池的实现参考了jemalloc的原理，关于jemalloc的介绍可以参考:[jemalloc](https://www.facebook.com/notes/facebook-engineering/scalable-memory-allocation-using-jemalloc/480222803919/)或者自行google。  

宏观上来说，Netty对内存的管理分为两个层面。在为线程分配内存的过程中，会首先查找**线程私有缓存**（默认为线程开启缓存，可配置关闭），当私有缓存不满足需求时，会在内存池中查找合适的内存空间，提供给线程。：
+ 线程私有缓存 Cache 
    线程私有缓存因为可以避免多线程请求内存时的竞争，所以效率很高，但是也存在一些缺陷：最大缓存容量小，每个线程默认32k；使用不当可能会造成[内存泄漏](https://caorong.github.io/2016/08/27/netty-hole/).
+ 全局的内存 Arena
    全局共享的内存池支持堆内存和堆外内存（Direct Buffer）的申请和回收，其**内存管理的粒度**有以下几个单位：
    + Chunk：Netty向操作系统申请内存是以Chunk为单位申请的，内存分配也是基于Chunk。Chunk是Page为单元的集合，默认16M。
    + Page: 内存管理的最小单元，默认8K
    + SubPage: Page内内存分配单元。

<img src="unit.png" width = "500" height = "400" align=center />

Netty逻辑上将内存大小分为了tiny, small, normal, huge 几个单位。申请内存大于Chunk size 为huge，此时不在内存池中管理，由JVM负责处理；当Client申请的内存大于一个Page的大小（normal）, 在Chunk内进行分配; 对tiny&small大小的内存，在一个Page页内进行分配。针对上述几种粒度的内存块的管理，其实现上包含以下几个组件（类）：

+ PoolArena：内存分配中心
+ PoolChunk：负责Chunk内的内存分配
+ PoolSubpage：负责Page内的内存分配

用一幅图概括内存池的布局与管理如下：

<div align = center>

![Global](global.jpg)

</div>

按照由繁到简的顺序（个人观点），上述组件的实现原理剖析可以依次参见：
1. {% post_link poolarena Netty 是怎么做内存管理-PoolArena %}
2. {% post_link poolchunk Netty 是怎么做内存管理--PoolChunk %}
3. {% post_link poolsubpage  Netty 是怎么做内存管理--PoolSubPage %}

最后，对线程私有缓存的管理解析及内存释放的相关内容，请阅读[Netty内存管理-线程私有缓存]()和[Netty内存管理-内存释放]()。
