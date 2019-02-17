---
title: MySQL 数据可靠性是怎么保证的？
toc: true
thumbnail: /images/
date: 2019-02-15 15:47:10
author:
tags:
---
只要redo log和binlog保证持久化到磁盘，就能保证MySQL异常重启后，数据可以恢复。
<!--more-->
## MySQL 数据可靠性保证 - 两阶段提交
### 概述
2PC即Innodb对于事务的两阶段提交机制。当MySQL开启binlog的时候，会存在一个内部XA的问题：事务在存储引擎层（redo log）commit的顺序和在binlog中提交的顺序不一致的问题。如果不使用两阶段提交，那么数据库的状态有可能用它的日志恢复出来的库的状态不一致。

事务的commit分为prepare和commit两个阶段：
1、prepare阶段：redo持久化到磁盘（redo group commit），并将回滚段置为prepared状态，此时binlog不做操作。
<img src="prepare.png" width = "600" height = "300" align=center alt=""/>
2、commit阶段：innodb释放锁，释放回滚段，设置提交状态，binlog持久化到磁盘，然后存储引擎层提交。
<img src="commit.png" width = "600" height = "300" align=center alt=""/>

### 崩溃恢复
一条更新语句的2PC流程图如下：
<img src="2pc.png" width = "400" height = "200" align=center alt=""/>

#### **崩溃恢复目标**
避免binlog 主备库恢复数据不一致；避免binlog恢复出来的数据与redolog恢复出来的数据不一致。

#### **崩溃恢复时的判断原则**
1. 如果redo log里面的事务是完整的，也就是已经有了commit标识，则直接提交；
2. 如果redo log里面的事务只有完整的prepare,则判断对应的事务binlog是否存在并完整：
    a.如果是，则提交事务；
    b.否则，回滚事务。

时刻A：写入redo log处于prepare阶段之后，写binlong之前，放生了crash. 由于此时binlog还没写，redo log 也还没提交，所以崩溃恢复的时候，事务会回滚。这时候binlog还没写，所以也不会传到备库。
时刻B：对应原则2a。

MySQL引入了binlog-checksum参数用来验证binlog的正确性<font color="#FF0000">以此验证事务binlog的正确性</font>。而redo log 和 binlog 的数据格式有一个共同的数据字段 - XID。 崩溃恢复的时候，会按顺序扫描redo log:
* 如果碰到既有prepare, 又有commit的redo log，就直接提交；
* 如果碰到只有prepare，而没有commit的redo log, 就拿着这个redo log的XID 去binlog 找对应的事务。<font color="#FF0000">以此关联起redo log和binlog</font>。

<font color="#FF0000">两阶段提交是经典 的分布式系统问题</font>。举例来说，对于InnoDB引擎，如果redo log提交完了，事务就不能回滚。而如果redo log直接提交，然后binlog 写入失败，则InnoDB又回滚不了，数据和binlog日志又不一致了，因为<font color="#FF0000">存在binlog和redo log两种日志且存在主从环境，就需要两阶段提交</font>。两阶段提交就是为了给所有人一个机会，当每个人都说“我OK”的时候，再一起提交。

>那如果只用binlog做崩溃恢复，避免费事的两阶段提交可以吗？

答案是<font color="#FF0000">binlog是不能做崩溃恢复的</font>。原因1 - binlog 没有能力恢复“数据页”。如下图因为binlog 只记录了逻辑操作，而非像redo log记录数据页磁盘的数据变更。当mysql crash时候，例如binlog1 记录的事件，如果没有WAL 刷盘，binlog是会丢数据的。也就是binlog没有能力恢复数据页。
<img src="binlog-replay.png" width = "300" height = "200" align=center alt=""/>

但是binlog 也有自己的特殊用途，不能完全取消：
1. 归档。redo log 是循环写，这样历史日志没法保留，redo log无法起到归档的作用。
2. 复制。MySQL高可用的基础，就是binlog复制。还有很多公司有异构系统（比如一些数据分析系统），这些系统就靠消费MySQL的binlog 来更新自己的数据。

> 如何通过redo log做崩溃恢复？

1.如果是正常运行的实例的话，数据页被修改后，跟磁盘的数据页不一致，称为脏页。最终数据罗盘，就是把内存中的数据页写盘，这个过程与redo log无关系。
2.InnoDB如果判断一个数据页可能在崩溃恢复时候丢失了更新，就会将它读到内存，然后让redo log 更新内存内容。更新完成后，内存页变成了脏页，就回到了第一种情况。

## binlog 写入机制
binlog 写入逻辑比较简单：事务执行过程中，先把日志写到binlog cache， 事务提交的时候，再把binlog cache写到binlog文件中。
<img src="binlog-write.png" width = "500" height = "300" align=center alt=""/>
每个线程有自己binlog cache, 但是共用同一份binlog文件。
其中write，指的是把日志写入到文件系统的page cache,并没有把数据持久化到磁盘，所以速度比较快。fsync是将数据持久化到磁盘的操作。一般情况下，fsync才占磁盘IOPS.

write 和 fsync 的时机，是由参数 sync_binlog 控制的：
1.sync_binlog=0 的时候，表示每次提交事务都只 write，不 fsync；
2.sync_binlog=1 的时候，表示每次提交事务都会执行 fsync；
3.**sync_binlog=N(N>1) 的时候，表示每次提交事务都 write，但累积 N 个事务后才 fsync**。

在出现 IO 瓶颈的场景里，将 sync_binlog 设置成一个比较大的值，可以提升性能。在实际的业务场景中，考虑到丢失日志量的可控性，一般不建议将这个参数设成 0，比较常见的是将其设置为 100~1000 中的某个数值。风险是当主机发生异常重启，会丢失最近N个事务的binlog日志。

<img src="sync_binlog.png" width = "500" height = "300" align=center alt="生产环境sync_binlog配置"/>

## redolog 写入机制
redo log 三种状态：
<img src="redolog-status.png" width = "500" height = "300" align=center alt="MySQL redo log存储状态"/>
1. 存在redo log buffer中，物理上在MySQL进程内存中；
2. 写到磁盘write, 但是没有持久化fsync,物理上是在文件系统的page cache里面;
3. 持久化到磁盘，对应的是hard disk.

日志写到 redo log buffer 是很快的，wirte 到 page cache 也差不多，但是持久化到磁盘的速度就慢多了。

InnoDB 有一个后台线程，每隔 1 秒，就会把 redo log buffer 中的日志，调用 write 写到文件系统的 page cache，然后调用 fsync 持久化到磁盘。

为了控制 redo log 的写入策略，InnoDB 提供了 innodb_flush_log_at_trx_commit 参数，它有三种可能取值：
1.设置为 0 的时候，表示每次事务提交时都只是把 redo log 留在 redo log buffer 中 ;
2.设置为 1 的时候，表示每次事务提交时都将 redo log 直接持久化到磁盘；
3.设置为 2 的时候，表示每次事务提交时都只是把 redo log 写到 page cache。
<img src="innodb_flush_log_at_trx_commit.png" width = "500" height = "300" align=center alt="生产环境innodb_flush_log_at_trx_commit配置"/>

注意，事务执行中间过程的 redo log 也是直接写在 redo log buffer 中的，这些 redo log 也会被后台线程一起持久化到磁盘。也就是说，一个没有提交的事务的 redo log，也是可能已经持久化到磁盘的。

## 组提交
MySQL是如何保证在频繁刷redo log到磁盘情况的同时保证较高的TPS的？ -- 一次刷一组 - 组提交。
### LSN
LSN：log sequence number日志逻辑序列号。LSN是单调递增的，用来对应redo log的一个个写入点。 每次写入长度为length的redo log， LSN的值就会加上length。

<img src="lsn.png" width = "500" height = "300" align=center alt=""/>
1. 第一个到达的事务会被选为这组的leader;
2. 等 trx1 要开始写盘的时候，这个组里面已经有了三个事务，这时候 LSN 也变成了 160；
3. trx1 去写盘的时候，带的就是 LSN=160，因此等 trx1 返回时，所有 LSN 小于等于 160 的 redo log，都已经被持久化到磁盘；
4. 这时候 trx2 和 trx3 就可以直接返回了。

注意，这里“组”的划分为在MySQL进程内存的所有事务组成一组。在并发更新场景下，第一个事务写完redo log buffer以后，接下来fsync 越晚调用，组员可能越多，节约IOPS的效果就越好。

为了让fsync带的组员更多，MySQL的优化：**拖时间**。
两阶段提交的实际图为：
<img src="2pc-detail.png" width = "400" height = "200" align=center alt=""/>
MySQL为了让组提交的效果更好，把redo log做fsync的时间拖到了步骤1后,这样binlog也可以组提交了，这样可以减少IOPS的消耗。

### WAL机制强大的原因
1. redo log和binlog都是顺序写，磁盘的顺序写比随机写速度要快；
2. 组提交机制，可以大幅度降低磁盘的IOPS消耗。

## 最后一个问题
如果想避免MySQL出现IO瓶颈，可以怎么做提升性能？
<p>设置 binlog_group_commit_sync_delay 和 binlog_group_commit_sync_no_delay_count 参数，减少 binlog 的写盘次数。这个方法是基于“额外的故意等待”来实现的，因此可能会增加语句的响应时间，但没有丢失数据的风险。</p>
<p>将 sync_binlog 设置为大于 1 的值（比较常见是 100~1000）。这样做的风险是，主机掉电时会丢 binlog 日志。</p>
<p>将 innodb_flush_log_at_trx_commit 设置为 2。这样做的风险是，主机掉电的时候会丢数据。</p>

