---
title: Redis持久化总结
toc: true
thumbnail: /images/egret.jpg
date: 2018-07-30 17:49:50
author: NX
tags:
  - Redis
categories: 中间件
---
本篇主要关于Redis持久化的总结。

<!-- more -->

### Why we need persistence

持久化的作用是为了在Redis关闭或者意外宕机的情况下，能恢复内存中的数据。Redis在日常的使用场景中，有常见的两种用途：

1.当数据库使用（不推荐），此时持久化的作用显而易见；

2.做缓存使用，虽然Redis挂掉不会影响我们的数据本身，但如果Redis挂了再重启，开启了固化功能后，内存里能够快速恢复热数据，不会瞬时将压力压到数据库上，没有一个cache预热的过程。

### Pros and cons for rdb and aof

#### RDB优点

1. RDB文件很紧凑（compact），它保存了 Redis 在某个时间点上的数据集。 这种文件非常适合用于进行备份。
2. RDB的恢复时间快，原因有两个，一是RDB文件中每一条数据只有一条记录，不会像AOF日志那样可能有一条数据的多次操作记录。所以每条数据只需要写一次就行了。另一个原因是RDB文件的存储格式和Redis数据在内存中的编码格式是一致的，不需要再进行数据编码工作。在CPU消耗上要远小于AOF日志的加载。

#### RDB缺点

1. 安全性差，虽然 Redis 允许你设置不同的保存点（save point）来控制保存 RDB 文件的频率， 但是， 因为RDB 文件需要保存整个数据集的状态， 所以它并不是一个轻松的操作。 因此你可能会至少 5 分钟才保存一次 RDB 文件。 在这种情况下， 一旦发生故障停机， 你就可能会丢失好几分钟的数据。
2. 执行开销大，每次保存 RDB 的时候，Redis 都要 fork() 出一个子进程，并由子进程来进行实际的持久化工作。 在数据集比较庞大时， fork()可能会非常耗时，造成服务器在某某毫秒内停止处理客户端； 如果数据集非常巨大，并且 CPU 时间非常紧张的话，那么这种停止时间甚至可能会长达整整一秒。

#### AOF优点

1. 安全性高，可通过fsync策略来控制，默认每一秒执行一次，此时最多丢失2秒内的数据。
2. 持久化协议可读性强，操作灵活度高。比如：如果你不小心执行了 *FLUSHALL* 命令， 但只要 AOF 文件未被重写， 那么只要停止服务器， 移除 AOF 文件末尾的 *FLUSHALL* 命令， 并重启 Redis ， 就可以将数据集恢复到 *FLUSHALL* 执行之前的状态。

#### AOF缺点

1. 对于相同的数据集来说，AOF 文件的体积通常要大于 RDB 文件的体积。数据恢复的比较慢。
2. 根据所使用的 fsync 策略，AOF 的速度可能会慢于 RDB 。 在一般情况下， 每秒 fsync 的性能依然非常高。对于RDB来说出去fork()本身可能造成的问题外，子进程就会处理接下来的所有保存工作，父进程无须执行任何磁盘操作，性能更好。

###  Online configuration

| Config                      | Value      |             说明              |
| --------------------------- | ---------- | :---------------------------: |
| auto-aof-rewrite-percentage | 200        |  AOF文件大小翻倍出发rewrite   |
| auto-aof-rewrite-min-size   | 2147483648 |   AOF文件触发重写的最小size   |
| no-appendfsync-on-rewrite   | yes        | 在日志重写时，AOF追加只写缓存 |
| appendonly                  | yes        |            开启AOF            |
| appendfsync                 | everysec   |           每秒刷盘            |
| rdbcompression              | yes        |          开启RDB压缩          |
| rdbchecksum                 | yes        |         开启RDB校验和         |
| save                        | null       |       RDB自动触发未配置       |

特殊说明：在同时执行bgrewriteaof操作和主进程写aof文件的操作，两者都会操作磁盘，而bgrewriteaof往往会涉及大量磁盘操作，这样就会造成主进程在写aof文件的时候出现阻塞的情形。no-appendfsync-on-rewrite被设置为yes后，在日志重写时，主进程不进行命令追加的刷盘操作，而只是将其放在缓冲区里，避免与重写造成DISK IO上的冲突。如果rewrite的过程中，Redis down掉的话 丢失的数据 就不是之前appendfsync 定下的策略，而是整个 rewrite 过程中的所有数据。

 
