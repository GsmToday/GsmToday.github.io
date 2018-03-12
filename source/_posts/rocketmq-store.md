---
title: RocketMQ源码分析3--Store数据出存储
toc: true
banner: /images/mouse2.jpg
date: 2018-03-11 14:56:03
author: GSM
tags:
  - RocketMQ
categories: 消息队列
---
本文是[RocketMQ源码分析系列](http://localhost:4000/tags/RocketMQ/)之三，如有疑问或者技术探讨，可以[email me](gsmuestc@163.com),欢迎探讨.

<!-- more -->
# 设计思路
关键词： CommitLog, ConsumeQueue, 内存映射文件

一个产品的技术选型一般都要基于其使用场景，RocketMQ的数据存储也不例外。在数据存储方面，RocketMQ采用了将数据(所有topic的消息)只写在了一个唯一的文件(CommitLog)里面. 之所以这么设计，是有其历史原因的:RocketMQ的最初使用场景是为了支持淘宝双十一实时订单场景(大数据量，topic-partition多)，Rocket的设计最初借鉴了Kafka并试图克服其在topic-partition增多时候的不足。

先来看看Kafka是怎么做数据存储的。

在Kafka的架构设计上，消息以topic分类，每个topic存储在多个partition上，一个partition对应一个单独的log文件上。消息不断追加到log的末尾（顺序写）。partition可以分布在不同的机器上，因此一个topic的消息可以水平扩展到多机器上。
![一个拥有四个partition的topic](kafka-partition.png)
![Kafka log](kafka-log.png)
当Producer想要写入消息时候，消息会根据其key的哈希值分派到对应的partition上，然后追加写到partition的log文件。但是从IO层面看，这种多topic-多partition方式，对于每个文件来说虽然是顺序IO.但是当并发读写多个partition，在文件系统的磁盘层面，是随机IO写到多个partition的。[由于磁盘是随机读写慢，顺序读写快](https://tech.meituan.com/about-desk-io.html)。因此，[实验证明](http://jm.taobao.org/2016/04/07/kafka-vs-rocketmq-topic-amout/)：topic数量增加到一定程度，Kafka性能急剧下降。

为了解决这个问题，RocketMQ的消息是**存储在一个单一的CommitLog文件里**，从而避免是磁盘的随机IO。

另外Kafka针对Producer和Consumer使用了同1份存储结构，而RocketMQ却为Producer和Consumer分别设计了不同的存储结构，Producer对应CommitLog, Consumer对应ConsumeQueue。
RocketMQ把topic的所有queue的消息存储在一个CommitLog里, 然后再异步分发给ConsumeQueue.  ConsumeQueue是逻辑队列，并不真正存储消息的内容，仅仅存储消息在CommitLog的位移(offset)，也就是说ConsumeQueue其实是CommitLog的一个索引文件。ConsumeQueue是定长的结构，每1条记录固定的20个字节。很显然，Consumer消费消息的时候，要读2次：
1. 先读ConsumeQueue得到offset
2. 再读CommitLog得到。 

有关数据存储，可以看出通过将消息都追加写到一个CommitLog文件，实现了顺序写提高了磁盘IO性能。但是这里还有一个问题，Consumer在读消息的时候，实际上是一个随机读磁盘的过程。那么RocketMQ是怎么优化这一点的呢？

可以看到对于CommitLog和ConsumeQueue源代码中都有一个成员MapedFileQueue。这是因为Consumer消费消息过程中使用了**零拷贝（mmap+write）**，[mmap](https://www.cnblogs.com/huxiao-tee/p/4660352.html)是一种内存映射文件的方法，即将一个文件或者其他对象映射到进程的地址空间，实现文件磁盘地址和进程虚拟地址空间中的一段虚拟地址的一一映射关系。实现这样的映射关系后，进程就可以采用指针的方式读写操作这一段内存。而系统会自动回写脏页面到对应的文件磁盘，即完成了对文件的操作而不比调用read,write等系统调用函数。相反，内核空间对区域的修改也直接反应到用户空间，从而实现不同进程间的文件共享。[有关零拷贝推荐此文](http://www.linuxjournal.com/article/6345)。

<img src="consumequeue.png" width = "500" height = "300" alt="数据存储逻辑结构" align=center />
# 数据存储功能
消息队列在使用过程中都会面临着如何承载消息堆积并在合适的时机投递的问题。处理堆积的最佳方式就是[数据存储](https://tech.meituan.com/mq-design.html)。

从功能上讲，数据存储用于存储：
* Producer生产的消息
* Consumer的逻辑队列: 记录消息在CommitLog中的offset
* 索引：用于查询消息，当用户想要查询topic下的某个key消息时，能够快速响应.
* 主从复制：用于实现Master - Slave之间的信息同步。

核心类：
```java
DefaultMessageStore {
    private final MessageStoreConfig messageStoreConfig; //存储相关配置，例如存储路径，CommitLog路径及大小
    private final CommitLog commitLog; 
    private final ConcurrentMap<String/* topic */, ConcurrentMap<Integer/* queueId */, ConsumeQueue>> consumeQueueTable; //topic的消费队列表
    private final FlushConsumeQueueService flushConsumeQueueService; //CQ刷盘服务线程
    private final CleanCommitLogService cleanCommitLogService;//磁盘超过水位进行清理
    private final CleanConsumeQueueService cleanConsumeQueueService;
    private final IndexService indexService; //索引服务 - 用于创建索引文件集合，当用户想要查询某个topic下某个key的消息时，能够快速响应  主要用于查询消息用的，根据topic+key获取消息,
    private final AllocateMappedFileService allocateMappedFileService;
    private final ReputMessageService reputMessageService; //CommitLog异步构建CQ和索引文件的服务。
    private final HAService haService; //主备同步服务
    private final ScheduleMessageService scheduleMessageService;//延迟消息：先把消息投递到delay topic暂存，然后通过定时器把delay topic暂存的消息投递到真实的topic.
    private final StoreStatsService storeStatsService; //存储统计服务
    private final TransientStorePool transientStorePool;

    private final RunningFlags runningFlags = new RunningFlags();
    private final SystemClock systemClock = new SystemClock();
    private final ScheduledExecutorService scheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor(new ThreadFactoryImpl("StoreScheduledThread"));
    private final BrokerStatsManager brokerStatsManager; //Broker统计服务
    private final MessageArrivingListener messageArrivingListener; //消息到达监听器
    private final BrokerConfig brokerConfig;
    private volatile boolean shutdown = true;
    private StoreCheckpoint storeCheckpoint; //检查点
    private AtomicLong printTimes = new AtomicLong(0);
    private final LinkedList<CommitLogDispatcher> dispatcherList; //转发CommitLog到CQ
    private RandomAccessFile lockFile;
    private FileLock lock;
    boolean shutDownNormal = false;
} //存储模块核心类,提供数据功能API 


```
## Producer生产消息

```java
PutMessageResult result = this.commitLog.putMessage(msg); // 向CommitLog追加消息
```
![Producer-putMessage流程图](putMessage.png)

broker在接收到Producer发送的消息之后，会同步或者异步地刷盘。一般来说，数据存储为了追求高吞吐，会先将数据写入到内存，然后再刷盘到磁盘中进行持久化。
```java
private final FlushCommitLogService flushCommitLogService;
```
- 同步刷盘：当数据写到内存之后立刻刷盘，在保证刷盘成功的前提下响应client
- 异步刷盘：数据写入内存后，直接响应client, 异步将内存中的数据持久化到磁盘上。

## Consumer消费消息
## 索引
索引组件用于创建索引文件集合，当消费者想要获取某个topic下的某个key的消息时候能够快速响应。

在DefaultMessageStore时候，会启动一个线程:
```java
this.reputMessageService.start();// 这步操作会创建
```
该线程每隔一秒就会根据消息构建DispatcherRequest类，从CommitLog中读取和构建CommitLog和IndexFile.

构建ConsumeQueue:
```java
 class CommitLogDispatcherBuildConsumeQueue implements CommitLogDispatcher {

        @Override
        public void dispatch(DispatchRequest request) {
            final int tranType = MessageSysFlag.getTransactionValue(request.getSysFlag());
            switch (tranType) {
                case MessageSysFlag.TRANSACTION_NOT_TYPE:
                case MessageSysFlag.TRANSACTION_COMMIT_TYPE:
                    DefaultMessageStore.this.putMessagePositionInfo(request);
                    break;
                case MessageSysFlag.TRANSACTION_PREPARED_TYPE:
                case MessageSysFlag.TRANSACTION_ROLLBACK_TYPE:
                    break;
            }
        }
    }
```

```java
   public void putMessagePositionInfo(DispatchRequest dispatchRequest) {
        ConsumeQueue cq = this.findConsumeQueue(dispatchRequest.getTopic(), dispatchRequest.getQueueId());
        cq.putMessagePositionInfoWrapper(dispatchRequest);
    }
```
构建存放该消息的索引，并放入缓存
## 主从复制


# 数据结构
##MappedFile
MappedFileQueue + Maped File 保存存放在物理机器上的文件信息。
Mapped File: 存储具体的文件信息: 包括文件路径，文件名(文件起始偏移)，写位移，读位移等等信息，同时使用了虚拟内存提高IO效率。
```java
//JVM中映射的虚拟内存总大小
private static final AtomicLong TotalMapedVitualMemory = new AtomicLong(0);
//JVM中mmap的数量
private static final AtomicInteger TotalMapedFiles = new AtomicInteger(0);
private final String fileName;//文件名即是消息在此文件的中初始偏移量 - 文件的起始偏移量是commitlog目录文件的最小offset
private final long fileFromOffset; //也就是/data/store/consumequeue/xx/中各个文件的文件名，表示对应在commitlog中的偏移量，可以参考 MapedFileQueue.load
private final int fileSize;//文件大小
private final File file; //文件句柄
private final MappedByteBuffer mappedByteBuffer;//映射的内存对象
//当前文件的写位置
private final AtomicInteger wrotePostion = new AtomicInteger(0); //mapfile文件写入的物理位置。
//当前文件Flush到的位置
private final AtomicInteger committedPosition = new AtomicInteger(0);//mapfile已经刷盘到某一个物理位置
private FileChannel fileChannel;//映射的FileChannel对象
private volatile long storeTimestamp = 0; //最后一条消息保存时间
private boolean firstCreateInQueue = false;//是不是刚刚创建的Map
```
DefaultMessageStore初始化时候：
```java
 this.dispatcherList = new LinkedList<>();
        this.dispatcherList.addLast(new CommitLogDispatcherBuildConsumeQueue());
        this.dispatcherList.addLast(new CommitLogDispatcherBuildIndex());
```
##CommitLog
CommitLog是存储消息的物理结构。
// 内存映射队列 
private final MapedFileQueue mapedFileQueue;
// 
# 参考
1. http://blog.csdn.net/chunlongyu/article/details/54576649
2. [Dengshenyu - Kafka系列](http://www.dengshenyu.com/%E5%88%86%E5%B8%83%E5%BC%8F%E7%B3%BB%E7%BB%9F/2017/11/06/kafka-Meet-Kafka.html)