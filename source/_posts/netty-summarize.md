---
title: Netty入门综述
toc: true
thumbnail: /images/dog.jpg
date: 2018-02-13 14:31:51
author: GSM
tags:
  - Netty
categories: 学习积累
---
本文是笔者自学Netty过程中总结出来的一个类似专题入门的综述文章，主要阐述以下几点关于Netty的问题:
* IO模型发展历程
* Netty基本组件
* Netty线程模型

希望在探讨清楚这几个问题的同时可以让自己和读者(如果有的话..)入门。本文参照了很多业界人士的深刻见解，在文中都有标注，如读者有空可以直接读原文。
<!-- more -->
# I/O模型发展
## 早期的Socket API实现网络编程
[Ref](https://www.zhihu.com/question/24322387)
1. Server端创建一个ServerSocket, 绑定一个端口，监听`listen()`此端口上的连接请求
2. 服务器使用`accept（）`并阻塞直到一个连接请求建立。随后返回一个新的socket用于客户端和服务端之间的通信
3. 一系列客户端请求这个端口
4. 启动一个新线程处理连接
    1. 读socket，得到字节流
    2. 解码协议，得到HTTP请求对象
    3. 处理HTTP请求，得到一个结果，封装成一个HttpResponse对象
    4. 编码协议，将结果序列化字节流
    5. 写Socket，将字节流发给客户端
5. 继续循环步骤3
<img src="serverClient.jpg" width = "500" height = "300" alt="server&client" align=center />

早期的网络编程是一种阻塞的IO模型，如果存在多个客户端的连接socket就需要创建多个线程。这种无疑会造成大量线程空闲，管理和切换上资源的浪费。
## NIO - Selector多路复用模型
([关于单路复用，使用国际象棋的大师车轮战这个例子更容易理解](https://gsmtoday.github.io/2017/10/29/nginx-principle/))

单路的问题是每个请求响应独占一个连接/线程，并独占连接网络读写；这样导致连接在有大量时间被闲置无法更好地利用网络资源。由于是独占读写IO，这样导致并发量高的时候就会出现性能问题[著名的C10K问题](https://blog.csdn.net/chenrui310/article/details/101685827)。为了解决这个一个连接就要开一个线程的浪费，业界提出了多路复用模型，Java NIO(Non-blocking I/O，在Java领域，也称为New I/O）)实现了它。NIO包使用了Selector-非阻塞IO模型，可以在一个进程或者线程中处理多个请求。不用再一个请求开多个线程。解决C10K问题。

Selector多路复用模型使用了**事件通知**API以确定在一组非阻塞socket中有哪些已经就绪能够进行I/O相关操作。因为可以在任意事件检查任意的读操作or写操作的状态，所以一个单一的线程便可以处理多个并发连接。

例如如图，selector负责检查socketA-C哪些需要的数据已经准备好了，并告知thread. 假如此时socketA，socketB数据准备好了，selector把这两个socket准备已准备好的“事件”通知给thread. Thread依次去处理socketA和socketB. 这样只有当连接上有数据的时候进程才去处理，这套处理机制对应着Linux操作系统的epoll和Mac的Kqueue.

这种模型的好处是使用较少的线程可以处理大量连接，减少线程切换和管理的代价。但是一旦系统的并发量特别大，使用单一的线程处理是难以满足客户端要求的。另外Java原生的NIO使用并不是很方便, 因此Netty应运而生。
![selector](selector.jpg)

多路复用的实现使用到了select,poll,epoll. 再说一下select 和 epoll.
多路复用用同一个进程来同时处理若干Socket。但是传统做法是直接循环处理多个Socket，任一文件句柄的不成功会阻塞住整个应用。于是有了select，poll epoll. select是在读取文件前，先检查状态，ready了就进行处理，不然不处理。缺点是要排查所有文件效率不高。epoll则是通知机制，selector通知工作线程哪个socket连接数据准备好了。

# Netty 简介
高性能架构的设计集中在：
* 尽量提升单服务器的性能，将单服务器的性能发挥到极致。
* 如果单服务器无法支撑性能，设计服务器集群方案。

单服务器高性能的关键之一就是：服务器采取的并发模型。并发模型有如下两个关键设计点：服务器如何管理连接以及服务器如何处理请求。以上两个设计点最终都和操作系统的I/O模型及进程模型相关。

我们先来看看Netty之前的**服务器网络通信框架模型**都有哪些:
1.最基本的是使用阻塞I/O服务器单线程逐个处理连接请求。
2.接着发展为使用多线程处理请求。一旦一个连接建立成功后，创建一个单独的线程处理其I/O操作。显然这种通信框架在高并发下线程数激增，服务器难以支撑。
3.接着网络通信框架发展为使用线程池处理请求，将请求放入线程池的任务队列，避免大量的线程造成的切换代价。
4.Reactor模式。Reactor模式可以理解为工作线程(池)+IO多路复用机制，即IO多路复用统一监听事件，收到事件后分配给某个进程。Reactor模式的核心组成部分包括Reactor和处理资源池，其中Reactor负责监听和分配时间，处理资源池负责处理事件。具体Reactor的数量可以变化，可以是一个Reactor，也可以是多个Reactor。资源池的数量可以变化，可以单线程也可以是个线程池。将Reactor个数和处理资源池线程个数两个因素组组合起来，Reactor模式有三种典型实现方案：
- 单Reactor单线程模型，典型例子是Redis。
- 单Reactor多线程模型
- 多Reactor多线程模型，典型例子Nginx。
([更多关于Reactor模式Ref](http://www.infoq.com/cn/articles/netty-threading-model))
<img src="reactor.jpg" width = "500" height = "300" alt="reactor多线程模式" align=reactor多线程模式 />


现在来讲讲Netty, Netty使用了三种Reactor线程模型。Netty提供了一个<font color = "red">异步的事件驱动的网络通信框架，支持快速地开发可维护的高性能面向协议的服务器和客户端</font>。

Netty是建立在NIO基础之上，在NIO之上又提供了更高层次的抽象。在Netty里面，Accept连接可以使用单独的线程池去处理，读写操作又是另外的线程池来处理。当然，Accept连接和读写操作也可以使用同一个线程池来进行处理。而请求处理逻辑既可以使用单独的线程池进行处理，也可以跟放在读写线程一块处理。线程池中的每一个线程都是NIO线程。用户可以根据实际情况进行组装，构造出满足系统需求的并发模型。

从高层次的角度来看，Netty解决了两个关注领域：**技术**和**体系结构**。首先，它的基于Java NIO的异步和事件驱动的实现，保证了高负载下应用程序性能的最大化和可伸缩性。其次，Netty也包含了一组设计模式，将应用程序逻辑从网络层解耦，简化了开发过程，同时也最大限度提高了可测试性，模块化以及代码的可重用性。

Netty提供了内置的**常用编解码器**，包括行编解码器［一行一个请求］，前缀长度编解码器［前N个字节定义请求的字节长度］，可重放解码器［记录半包消息的状态］，HTTP编解码器，WebSocket消息编解码器等等。Netty提供了一些列生命周期回调接口，当一个完整的请求到达时，当一个连接关闭时，当一个连接建立时，用户都会收到回调事件，然后进行逻辑处理。

Netty可以同时管理多个端口，可以使用NIO客户端模型，这些对于RPC服务是很有必要的。Netty除了可以处理TCP Socket之外，还可以处理UDP Socket。

# Netty 核心组件

## <font color = "blue">Netty网络抽象代表：Channel(socket) + EventLoop + ChannelFuture<font>
`Channel`是Java NIO的一个基本构造。简单的说，可以把Channel看做是传入或者传出数据的载体socket。因此Channel可以被打开，关闭，连接或者断开连接。Channel提供的API大大的降低了直接使用socket类的复杂性。
<!-- <img src="" width = "500" height = "500" /> -->

![](netty-thread-model.png)

Channel有四种状态：
<img src="channel-state.jpg" width = "500" height = "300" />
当Channel的状态发生变化后，就会触发对应的事件。这些事件会被转发给ChannelPipeline中的ChannelHandler，其可以随后对它们做出响应。
<img src="channel-event.jpg" width = "300" height = "300" />

`EventLoop`代表netty控制流，多线程处理，并发。EventLoop定义了Netty核心抽象，一旦Channel注册到了EventLoop, EventLoop就处理连接的生命周期中Channel的所有IO操作。 一个`EventLoopGroup`包含一个或者多个EventLoop，一个EventLoop在它的生命周期内只和一个Thread绑定。所有由Eventloop处理的IO事件都将在它专有的`Thread`上被处理。一个Channel在它的生命周期内只注册一个EventLoop，一个EventLoop可能会被分配给多个Channel. 

Netty内部使用回调处理事件。Future: 因为Netty所有的IO操作都是异步的，因此当一个异步过程调用发出后，调用方不会立刻获得结果。但是调用方还是想获得这个结果怎么办？ Netty提供了`ChannelFuture`接口，其`addListener()`方法注册一个`ChannelFutureListener`,以便在某个操作完成时（无论是否成功）得到通知.

## <font color = "blue">应用业务逻辑组件：由责任链模式组织起来的Event和ChannelHandler<font>

Netty使用不同的事件`Event`通知我们状态的改变或者操作的状态，这使得我们可以基于已经发生的事件来触发适当的动作。例如IO连接的数据已经准备好，Netty会将这个时间通知工作线程。因为Netty是一个网络编程框架，因此Event是按照它们与IO数据流相关进行分类的。

事件可能包括Inbound event:
* 连接已经被激活/连接失活
* 数据读取
* 用户事件
* 错误事件

Outbound event:
* 打开或者关闭远程节点的连接
* 将数据写到或者flush到socket

<img src="pipeline.jpg" width = "400" height = "700" alt=ChannelPipeline的一个著名的inbound和outbound事件流模型 />

Netty使用了**IO事件驱动模型**，与NIO相比Netty允许使用者在不破坏现有处理逻辑的情况下定义自己的事件处理逻辑。这一优势要归功于Netty使用了[责任链模式](https://gsmtoday.github.io/2017/10/22/filter-chain-pattern/)。总的来说：Netty定义了一个管道[`ChannelPipeline`]，在管道中组织了多个拦截器[`ChannelHandler`]处理各个事件[`ChannelEvent`]. 如果用户想要定义自己的事件处理逻辑，他可以自己实现一个`ChannelHandler`。
<img src="design-pattern.jpg" width = "400" height = "700" alt="Netty的责任链模式" />

类的职责：
* `ChannelPipeline `: 责任链模式核心组件，ChannelHandler的容器，按顺序组织各个handler,并在它们之间转发事件。
* `ChannelHandlerContext` : 当ChannelHandler被添加到ChannelPipeline时，它将会被分配一个ChannelHandlerContext，ChannelHandlerContext代表了Pipeline和handler之间的绑定。封装一个具体的ChannelHandler,并为ChannelHanndler的执行提供一个线程环境(ChannelHanlderInvoker),可以理解为ChannelPipeline链路上的一个节点，节点里面包含有指向向前后节点的指针，事件在各个ChannelHandler之间传递，靠的就是ChannelHandlerContext
* `ChannelHandler`: 真正对IO事件作出响应和处理的地方，也是Netty暴露给业务代码的一个扩展点。一般来说，主要业务逻辑就是自定义ChannelHandler的方式实现的。
* `ChannelHandlerInvoker`: 为ChannelHandler提供一个运行的线程环境，默认的实现DefaultChannelHandlerInvoker有一个EventExecutor类型的成员，就是Netty的EventLoop线程，所以默认ChannelHandler的处理逻辑在EventLoop线程内。当然也可以提供不同的实现，替换默认的线程模型

关于`ChannelPipeline`，只需要了解DefaultChannelPipeline这个默认的实现类，这个类其实就是一个链表管理类，管理者每一个ChannelHandlerContext类型的节点，从它的addFirst、addLast、remove等成员方法就可以看出来.

`ChannelHandler`是一个顶级接口，有两个子接口ChannelInboundHandler和ChannelOutboundHandler分别处理read和write相关的IO事件，为了便于业务方实现，两个子接口分别有一个简单的Adapter实现类，所有方法的默认实现都是代理给ChannelHandlerContext类（其实是不关心事件，直接转发给pipeline中下一个节点的handler来处理）。业务方实现自己的ChannelHandler时，推荐继承相应的Adapter类，只实现自己关心的事件的处理方法

### 编码器和解码器
网络数据是一系列的字节，当通过Netty发送或者接收一个消息的时候，就会发生一次数据转换。inbound msg会被解码，即从字节码转换为另一种格式，通常是Java对象。如果是outbound msg，则会发生相反方向的转换：从当前格式被编码为字节。使用Netty可以定制编解码协议，实现自己的特定协议的服务器。如果你实现的编解码协议是HTTP协议，那么你实现的就是HTTP服务器；如果你实现的协议是redis协议，那么你实现的就是Redis服务器。

### 引导类
Netty的引导类为应用程序的网络层配置提供了容器，这涉及到两种类型的引导：
- 服务端引导ServerBootstrap: 服务端引导类封装了服务端启动过程，包括端口绑定和监听等过程. 
- 客户端引导BootStrap：客户端引导类就是封装了客户端启动的过程，只要是创建socket，并发起connect调用，建立一个到服务端的链接的过程。

`BootStrap`和`ServerBootstrap`的区别除了网络编程中的作用之外，还有一个区别也很明显：BootStrap只需要一个`EventLoopGroup`，引导服务端的ServerBootstrap则需要两个EventLoopGroup。这是因为服务器需要两组不同的Channel,第一组将只包含一个ServerChannel，代表服务器自身的已绑定到某个本地端口的正在监听的套接字。而第二组将包含所有已创建的用来传递客户端的连接的channel.

# Netty线程模型
[Ref](http://www.infoq.com/cn/articles/netty-threading-model)
线程模型指定了操作系统，编程语言，框架或者应用程序的上下文中的线程管理的关键方面，它确定了代码的执行方式。

Java5引入了线程池Executor API,线程池通过利用缓存和重用线程极大地提高了性能。基本的线程池模式可以描述为：
1. 从线程池空闲列表选择一个Thread,并且指派它去运行一个已提交的任务（一个Runnable的实现）
2. 当任务完成时，将Thread返回给列表，使其可重用。

虽然线程池化和重用相对于简单地为每个任务创建和销毁线程是一种进步，但是它并不能消除由上下文切换所带来的开销，这种开销将随着线程数量的增加很快变得明显，并且在高负载下愈演愈烈。另外，线程安全性也是开发者必须要解决的问题。

Netty线程模型：通过`NioEventLoop`类的设计可以看出Netty线程模型设计原理 -- 一种并行单线程模型。我们知道Netty使用EventLoop来运行任务，处理所有IO连接。一个EventLoop将由一个永远都不会改变的Thread驱动，同时任务(Runnable/Callable)提交给EventLoop实现。为了优化线程池多线程切换的开销和线程安全问题，Netty采用了<font color = "red">串行化设计理念</font>。从消息的读取，编码以及后续handler的执行，始终都由IO线程NioEventLoop负责，这就意味着整个流程不会进行线程上下文的切换，数据也不会面临被并发修改的风险。对用户而言，甚至不需要了解Netty的线程细节，这确实是个非常好的设计理念。
<img src="Eventloop.jpg" width = "400" height = "700" alt="Netty的并行单线程模型" />
一个NioEventLoop聚合了一个多路复用Selector，因此可以处理成百上千的客户端连接，Netty的处理策略是每当有一个新的客户端接入，则从NioEventLoop线程组中顺序获取一个可用的NioEventLoop,当到达顺组上限之后，重新返回到0，通过这种方式，可以基本保证NioEventLoop的负载均衡。一个客户端连接只注册到一个NioEventLoop上，这样就避免多个IO线程去并发操作它。

Netty通过串行化设计理念降低了用户的开发难度，提升了处理性能。这种无锁化设计，避免了多线程成竞争导致的性能下降问题，利用线程组实现了多个串行化线程水平并行执行，线程之间并没有交集，这样既可以充分利用多核提升并行处理能力，同时避免了线程上下文的切换和并发保护带来的额外性能损耗。

## Netty线程模型分类
Netty的线程模型并不是一成不变的，它实际取决于用户的启动配置参数，通过设置不同的启动参数，Netty可以同时支持Reactor单线程模型，多线程模型和主从Reactor多线程模型。

### 服务端线程模型 - Reactor多线程模型的实现
服务端启动的时候，创建两个NioEventloopGroup，它们实际上是两个独立的Reactor线程池：
* 用于接收客户端的TCP连接，该线程池职责如下：
1. 接收客户端TCP连接，初始化Channel参数
2. 将链路状态变更时间通知给ChannelPipeline.

* 另一个用于处理I/O相关的读写操作，或者执行系统Task,定时任务等。
1. 异步读取通信对端的数据报，发送读事件到ChannelPipeline
2. 异步发送消息到通信对端，调用ChannelPipeline的消息发送接口
3. 执行系统调用Task
4. 执行定时任务Task,例如链路空闲状态监测任务
```java
EventloopGroup bossGroup = new NioEventLoopGroup(1);
EventloopGroup workerGroup = new NioEventLoopGroup(2);
EventloopGroup group = new NioEventLoopGroup();
try{
ServerBootStrap b = new ServerBootStrap();
b.group(bossGroup, workerGroup)
.channel(NioServerSocketChannel.class)
...
}
```
<img src="netty-server-thread1.jpg" width = "500" height = "500"  />
<img src="netty-server-thread2.jpg" width = "500" height = "500"  />
### 客户端线程模型
<img src="netty-client-thread.jpg" width = "500" height = "500"  />

### EventLoop接口
EventLoop接口通过运行任务去处理连接生命周期发生的事件。在这个模型中，一个EventLoop将由一个永远都不会改变的Thread驱动，同时任务（Runnable或者Callable）可以直接提交给EventLoop实现，以立刻执行或者调度执行。NioEventLoop是Netty的Reactor线程，它的职责如下：
1. 作为服务端Acceptor线程，负责处理客户端的请求接入;
2. 作为客户端connector线程，负责注册监听连接请求，判断异步连接结果；
3. 作为IO线程，监听网络读操作，负责从socketchannel读取报文；
4. 作为IO线程，负责向SocketChannel写入报文发送给对方
5. 作为定时任务线程，可以执行定时任务，例如链路空闲监测和发送心跳消息等；
6. 作为线程执行器可以执行普通的任务线程

# 参考
1. [Netty线程模型,李林峰](http://www.infoq.com/cn/articles/netty-threading-model)
2. http://docs.jboss.org/netty/3.1/guide/html/architecture.html#d0e1996
3. [责任链模式](https://gsmtoday.github.io/2017/10/22/filter-chain-pattern/)
4. [Netty系列之Netty高性能之道,李林峰](http://www.infoq.com/cn/articles/netty-high-performance)
5. [通俗的讲，Netty能做什么？,知乎](https://www.zhihu.com/question/24322387
6. [Netty4 学习笔记, zxh0](http://blog.csdn.net/zxhoo/article/details/17264263）
7. 建议阅读：[为什么建议Netty的I/O线程与业务线程分离](https://mp.weixin.qq.com/s/B7_QUNoWTix4lsw3ytGl4Q)
8. [Netty InfoQ 迷你书,李林峰](http://www.infoq.com/cn/minibooks/netty-in-depth)
