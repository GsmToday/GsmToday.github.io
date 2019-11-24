---
title: Nginx高性能和高扩展性背后的设计原理[译]
toc: false
thumbnail: /images/monkey.jpg
date: 2017-10-29 00:08:41
author: GSM
tags:
  - Nginx
categories: 学习积累
---

原文 : [https://www.nginx.com/blog/inside-Nginx-how-we-designed-for-performance-scale/]

Nginx 以其作为高性能高并发web服务器著称，而其高性能的表现皆依赖于其软件的架构设计。尽管有众多web服务器和应用服务器使用了单一进程/线程模型，Nginx 以其成熟的事件驱动模型脱颖而出。依赖其事件驱动模型，在现在的硬件条件下Nginx 能够支持大量的并发连接。

这篇文章将详细讲解Nginx 是如何工作的。

<!-- more -->

## Nginx 进程模型

为了理解Nginx 的架构设计，你应该了解Nginx 谁如何运行的。Nginx 有一个主进程（master process）和 若干工作进程（working processes）. 主进程拥有其他进程没有的权限，例如读取配置文件，绑定端口等。
```nginx
># service Nginx restart
* Restarting Nginx
# ps -ef --forest | grep Nginx
root 32475 1 0 13:36 ? 00:00:00 Nginx: master process /usr/sbin/Nginx \
-c /etc/Nginx/Nginx.conf
Nginx 32476 32475 0 13:36 ? 00:00:00 \_
Nginx: worker processNginx 32477 32475 0 13:36 ? 00:00:00 \_
Nginx: worker processNginx 32479 32475 0 13:36 ? 00:00:00 \_
Nginx: worker processNginx 32480 32475 0 13:36 ? 00:00:00 \_
Nginx: worker processNginx 32481 32475 0 13:36 ? 00:00:00 \_
Nginx: cache manager processNginx 32482 32475 0 13:36 ? 00:00:00 \_
Nginx: cache loader process
```
在四核机器上，Nginx 主进程创建四个工作进程和两个用来管理硬盘内容缓存的辅助进程。

## 为什么Nginx架构如此重要？
Unix 应用的基础是进程／线程(从linux OS的角度，进程和线程没有什么区别，他们的区别最大程度就说多大程度上他们共享存储空间)。一个进程或者线程是运行在cpu内核上的指令容器实例。大多数复杂的应用出于以下两个原因的考虑，会以多线程或者多进程的方式运行：

-  应用可以同时使用更多计算机内核计算。
-  可以很简单地实现并行操作（例如，同时处理大量连接）

然而，进程和线程使用并且消耗大量内存和操作系统其它资源。虽然现代操作系统可以同时处理大量体量小的进程/线程, 但是随之而来的是一旦内存不够带来的性能急剧下降，以及进程频繁切换导致的cpu资源浪费。

在设计网络应用时候，最普遍的方法是为每个连接分配一个线程/进程。 这种结构简单且容易实现，但是难以支持高并发连接。

## Nginx是如何工作的？
Nginx使用可以根据硬件资源来调节的进程模型。

- master process

    一个master 进程，只有它能够读配置，绑定端口等。master进程能够创建其他子进程为他干活。

- cache loader process

    在启动时候把硬盘缓存读进内存，它的资源消耗很低。

- cache manager process

    阶段性运行，管理缓存。

- worker processes

    实际干活的进程. 工作进程处理网络连接，从硬盘读写内容，和上游服务器通信。

推荐Nginx 配置:

worker processes的数量应该和计算机CPU数量相同，以此来最大程度利用计算机硬件。你可以如下配置实现：

```Nginx
worker_process auto;
```

当一个Nginx 服务器是活跃状态时候，只有工作进程们是忙碌的。每个工作进程以非阻塞形式处理大量的连接，以此减少多进程造成的上下文切换资源浪费。每个工作进程都是独立运行的单线程进程，可以处理大量新的网络连接。工作进程之间通过共享内存通信共享缓存数据，会话持续数据，以及其它共享资源。

![ngx-process](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_worker-process.png)

master进程会根据Nginx配置创建工作进程，并且分配给工作进程大量的监听套接字(listen sockets).

Nginx工作进程当等到监听套接字上的事件(accept_mutex和kernel socketsharding)时候会开始工作。新的连接到来时候会创建一个事件。这些连接被会分配给状态机（stat emachine）——HTTP状态机是最常用的，但Nginx还为流（原生TCP）和大量的邮件协议（SMTP，IMAP和POP3）实现了状态机。

状态机本质上是一组告知Nginx如何处理请求的指令，大多数和Nginx具有相同的web服务器也使用类似的状态机，只是实现不同罢了。

![](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_request-flow.png)

## 调度状态机
我们可以将状态机想象成国际象棋的规则。每个HTTP事务都是一局象棋比赛：棋盘的一端是web服务器（一个可以迅速做出决定的象棋大师），另一端是通过浏览器和较慢的网络进行操作的客户端（普通象棋选手）。然而游戏的规则是非常复杂的。例如，web服务器可能需要与各方沟通(代理一个上游的应用程序)，或者和认证服务器交流。web服务器的第三方模块甚至可以拓展比赛规则。

### 阻塞状态机
回忆一下我们之前对进程/线程的描述：是一组操作系统可调度的、运行在CPU内核上的指令集容器实例。大多数web服务器和web应用都使用进程(线程)连接一对一的模型去参与象棋比赛。每个进程或线程都包含一个将比赛玩到最后的指令。**在这个过程中，进程是由服务器来运行的，它的大部分时间都花在“阻塞（blocked）”上**，等待客户端完成其下一个动作：

![](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_blocking.png)

1. web服务器进程在监听套接字上监听新的连接（新的连接可以理解为客户端发起的新比赛）。
2. 一局新的比赛发起后，服务器进程就开始工作，每一步棋下完后都进入阻塞状态，等待客户端回复（客户端走下一步棋）。
3. 一旦比赛结束，web服务器进程会看看客户是否想开始新的比赛（这相当于一个存活的连接）。如果连接被关闭（客户端离开或者超时），web服务器进程会回到监听状态，等待下一句的比赛。

最重要的一点是每个http连接都需要一个专门的进程。这样的架构虽然简单且容易实现，**但是这会造成一个巨大的失衡：一个以文件描述符和少量内存为代表的轻量级HTTP连接，被映射到一个单独的进程或线程——它们是非常重量级的操作系统对象**。这在编程上是方便的，但它造成了巨大的浪费。

### Nginx是真正的大师
也许你听说过车轮表演赛，在比赛中一个大师级选手同时和多个对手比赛 — 这也是Nginx 工作进程如何“下棋”。每个工作进程都是一个象棋大师，可以同时处理大量的连接。

![](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_nonblocking.png)

1. 工作进程等待监听套接字和连接套接字上的事件；
2. 套接字上发生事件，工作进程会去处理这些事件。
        - 监听socket上的事件意味着棋手发起了一轮新的象棋比赛，工作进程会创建一个新的连接套接字
        - 连接socket上的事件意味着棋手下了一步棋。工作进程会立刻回复。

在网络中工作进程永远不会因为去等待对手下棋而阻塞。车轮战中，象棋大师跟一个对手下了一步棋后马上会继续和其他对手下棋。

### 为什么nginx这种单路复用的架构优于多进程阻塞架构？
Nginx的架构可以让每个工作进程支持几十万的连接。每个连接创建一个文件描述符，消耗少量的工作进程的内存。可以说每个进程上新增加一个连接额外的代价是非常小的。Nginx的工作进程可以保持固定的CPU占用率，并不浪费CPU资源。进程上下文切换也并不频繁。

在连接和进程一对一的阻塞架构上，每个连接需要大量的附加资源和开销，上下文切换是十分频繁的。

通过适当的系统调优，NGINX能大规模地处理每个工作进程数十万并发的HTTP连接，并且能在流量高峰期间不丢失任何信息。

## 配置更新和升级nginx
通过使用少量的工作进程，Nginx的进程模型使得配置、甚至是二进制文件本身的更新都非常高效。

![](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_load-config-1.png)

更新Nginx配置是很简单，轻量级并且可靠的操作。可以通过
```
nginx -s reload
```
更新加载Nginx的配置，该命令会检查磁盘上的配置，并给主进程发送一个SIGHUP信号。

当主进程接收到一个SIGHUP信号，主进程会做：
1. 重启配置，fork一套新的工作进程。这些新的工作进程会立即开始接受连接和处理流量（使用新的配置）。
2.给旧的那套工作进程发信号。工作进程停止接收新的网络连接。只要它们处理的HTTP请求结束了，它们就会干净地关闭连接。一旦所有的连接都被关闭，工作进程也就退出了。

这个过程会导致CPU占用率和内存使用的一个小高峰，但相比于从活动的连接中加载资源，这个小高峰可忽略不计。你可以在一秒内重新加载配置多次。极少情况下，一代又一代工作进程等待连接关闭时会出现问题，但即便出现问题，它们也会被立即解决掉。
![](https://cdn-1.wp.nginx.com/wp-content/uploads/2015/06/infographic-Inside-NGINX_load-binary.png)

## 结论
[Inside NGINX infographic](https://www.nginx.com/resources/library/infographic-inside-nginx/)总结了Nginx是如何运转的，看似简单，背后是针对Nginx数
十年的创新和优化，这才造就了Nginx在多种硬件上表现出良好的性能，同时还具备现代web应用所需要的安全性和可靠性。








