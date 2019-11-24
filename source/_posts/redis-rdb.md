---
title: Redis RDB持久化 - Redis源码分析
toc: true
thumbnail: /images/lu.jpg
date: 2018-07-30 17:49:50
author: NX
tags:
  - Redis
categories: 学习积累
---
Redis是内存数据库，持久化的功能可以将Redis在内存中的数据保存到磁盘里，避免数据在进程退出或者意外宕机等情况下意外丢失。Redis提供了两种持久化的方式，RDB和AOF。本文重点关注RDB相关的知识点。
<!-- more -->

### 初识RDB

RDB的持久化方式是将内存数据以快照的形式写入磁盘文件，并在Redis启动的时候，通过此文件恢复内存数据的状态。

```c
redis> set 1 2
redis> set 123456789 2
redis> set msg hello
redis> save
```

上述命令执行完成后，生成的rdb文件如下：(Redis version 4.0.8)

<img src="rdb文件.jpg" width = "600" height = "400" align=center title="dump.rdb文件" />

### RDB文件结构

从上面的二进制文件，不容易看出RDB文件的组织方式。实际上RDB文件的整体结构如下图所示:
<img src="rdb文件结构.png" width = "600" height = "400" align=center title="rdb文件" />

##### Magic+Version

开头的幻数，用来标识文件为RDB文件。Magic为固定的REDIS这五个字符，Version指定了当前RDB文件的版本号。结合上图的二进制dump文件，知道当前RDB文件的版本号为8。

##### AuxFields

一些记录redis状态的附属信息，包括redis-ver(版本), redis-bits(机器位数), ctime(创建时间), user-mem(内存占比)以及slave节点编号(可选)等。每个附属域字段的前置标识码都是250，即上图的372。

##### DB SNAPSHOT

每一个内存库的快照，以标识码SELECT_DB=254(即上图的376)开始，后面紧跟当前内存库的编号。标识码RESIZE_DB=251(即上图的376)开始的三段内存，记录了数据库中键值对个数和设置了到期时间的键值对个数。回顾上面的操作指令和二进制dump文件，我们设置了3条数据，没有设置过期时间，二者相稳合。

接下来就是每一条键值对的持久化信息。如果某一条记录设置了过期时间，并且执行SAVE持久化的时候，还没过期，那么会首先记录下到期的时间戳，以标识码252开始。由于Redis内置了多种数据类型，为了高效的存储和还原，其持久化时候的编码方式各异，但整体上都遵循type+key+value的格式。以dump文件倒数第二行中比较明显的 msg=》hello为例，做个简要说明：类型码0表示value在Redis内部是以字符串格式进行的编码，003表示key的长度为3，紧跟着key的字符串msg，value也一样。详细的每一种数据结构的编码方式会在后文阐述。

##### EOF

文件结束标识码EOF=255，即rdb dump文件中的377。

##### CHECK_SUM

RDB文件校验和，校验RDB文件是否损坏，8字节长，紧随EOF。

### 重点问题

对RDB文件有了基础的了解后，继续深入对RDB持久化的学习。在此之前，先思考下设计实现一个持久化机制前，需要重点解决那些问题？

1. 由于Redis内部有多种数据结构的实现，如何为每一种数据结构，设计一种编码方式，达到高效存储和还原的目的。
2. Redis需要快速的响应用户请求，如何在尽量小地影响用户访问的情况下，完成持久化的操作。
3. 对问题2的一个延伸，在哪些情况下触发持久化的流程，以及如何配置。
4. 持久化的具体实现流程和恢复流程。

带着这些问题，一一分析。

#### 如何设计存储协议，支持多种数据结构的存储

##### 长度编码

在介绍各种数据结构的持久化编码方式之前，先介绍一下RDB中对长度信息的编码。在RDB文件中有很多地方需要存储长度信息，如字符串长度、list长度等等。如果使用固定的int或long类型来存储该信息，在长度值比较小的时候会造成较大的空间浪费。Redis设计了一套针对长度的编码方式，主要通过读取第一字节的最高 2 位来决定接下来如何解析长度信息：

|         编码方式         | 占用字节 |              说明              |
| :----------------------: | :------: | :----------------------------: |
|     **00** \| 000000     |  1 byte  |     低6位表示长度，最大63      |
|    **01** \| 00··000     |  2 byte  |         低14位表示长度         |
| **10** \| 000000 + 4byte |  5 byte  | 后面4 byte表示长度，网络字节序 |
| **10** \| 000001 + 8byte |  9 byte  | 后面8 byte表示长度，网络字节序 |
|     **11** \| OBKIND     |  1 byte  |     低6位指定了对象的类型      |

OBKIND的几种定义如下

```
#define RDB_ENC_INT8  0    /* 8 bit signed integer */
#define RDB_ENC_INT16 1    /* 16 bit signed integer */
#define RDB_ENC_INT32 2    /* 32 bit signed integer */
#define RDB_ENC_LZF   3    /* string compressed with FASTLZ */
```

举个例子，执行如下几条Redis指令:

```c
redis>set -1 2
redis>set msg hello
redis>save
```

分析RDB的dump文件如图：
<img src="length_code.jpg" width = "400" height = "200" align=center title="长度编码" />

第一条指令的编码中300(对应十进制192)，二进制高两位都是1，表示采用了特殊的自定义编码，低6位都是0，说明使用了**RDB_ENC_INT8**的方式编码，即紧随着的内容377(对应二进制11111111)是一个有符号的整数-1，这与key是-1稳合，同理value是2；第二条指令dump比较直观，看下value hello的编码，005高二位都是0，表示采用1字节的长度编码，低6位的值就是5，说明value的长度为5， 与hello稳合。

##### String

由于Redis中key总是以字符串的形式组织，所以将其纳入字符串类型的value中一起分析，不再单独描述。字符串的编码方式有两种：整数编码(OBJ_ENCODING_INT )和普通字符串序列(REDIS_ENCODING_RAW)。

整数编码根据数字的大小有两种不同的实现方式：能在32bit中表示的有符号数，按照32位整数形式存储；否则按照字符数组的形式存储。核心代码如下：

```c
/* Save a long long value as either an encoded string or a string. */
ssize_t rdbSaveLongLongAsStringObject(rio *rdb, long long value) {
    unsigned char buf[32];
    ssize_t n, nwritten = 0;
    /*Encode as signed integer*/
    int enclen = rdbEncodeInteger(value,buf); 
    if (enclen > 0) {
        return rdbWriteRaw(rdb,buf,enclen);
    } else {
        /* Encode as string */
        enclen = ll2string((char*)buf,32,value); 
        serverAssert(enclen < 32);
        if ((n = rdbSaveLen(rdb,enclen)) == -1) return -1;
        nwritten += n;
        if ((n = rdbWriteRaw(rdb,buf,enclen)) == -1) return -1;
        nwritten += n;
    }
    return nwritten;
}
```

其中，整数编码的实现比较简单，根据字面值值能否使用1byte,  2byte,  4byte来表示，将数字按位存储到一个字节数组里。整体结构如下图：
<img src="RDB整数字符串编码.png" width = "300" height = "200" align=center title="RDB整数字符串编码" />

对于太长的数字值，Redis使用ll2string方法进行转换。一般我们把一个数字转换为字符表示时，比较直观的做法就是除10取余，然后再加上对应的数字字符。但是，对于long long这种很长的数字，效率就比较低下了。看下ll2string的实现：

```C
int ll2string(char *dst, size_t dstlen, long long svalue) {
    static const char digits[201] =
        "0001020304050607080910111213141516171819"
        "2021222324252627282930313233343536373839"
        "4041424344454647484950515253545556575859"
        "6061626364656667686970717273747576777879"
        "8081828384858687888990919293949596979899";
    int negative;
    unsigned long long value;

    /* The main loop works with 64bit unsigned integers for simplicity, so
     * we convert the number here and remember if it is negative. */
    if (svalue < 0) {
        if (svalue != LLONG_MIN) {
            value = -svalue;
        } else {
            value = ((unsigned long long) LLONG_MAX)+1;
        }
        negative = 1;
    } else {
        value = svalue;
        negative = 0;
    }

    /* Check length. */
    uint32_t const length = digits10(value)+negative;
    if (length >= dstlen) return 0;

    /* Null term. */
    uint32_t next = length;
    dst[next] = '\0';
    next--;
    while (value >= 100) {
        int const i = (value % 100) * 2;
        value /= 100;
        dst[next] = digits[i + 1];
        dst[next - 1] = digits[i];
        next -= 2;
    }

    /* Handle last 1-2 digits. */
    if (value < 10) {
        dst[next] = '0' + (uint32_t) value;
    } else {
        int i = (uint32_t) value * 2;
        dst[next] = digits[i + 1];
        dst[next - 1] = digits[i];
    }

    /* Add sign. */
    if (negative) dst[0] = '-';
    return length;
}
```

其核心实现的思想，比较直接，除以10比较慢，那就一次除以100，余数在表digits中查。由于每个余数可以占据digits中两个位置，可以通过余数乘以2来定位。

原生字符串编码的处理，如果字符串长度小于等于11，首先会尝试按照整数方式进行编码，否则如果配置了启动rdb_compression功能，并且字符串内容大于等于20个字节，则使用lzf算法压缩后存储。通过lzf算法压缩后，编码得到的结构如下图：

<img src="lzf压缩.png" width = "600" height = "400" align=center title="lzf压缩" />

如果前面两个条件都不满足，则先按照前述长度编码的方式，记录字符串的长度，然后逐个字节的写入字符串内容。

string浮点数的存储按照原生字符串的形式编码，验证如下图：

<img src="rdb浮点数编码.png" width = "600" height = "400" align=center title="浮点数编码" />

##### HASH

hash对象的编码方式有两种：ziplist和dict。

当哈希对象可以同时满足以下两个条件时列表对象使用ziplist编码：

1. 哈希对象保存的所有字符串元素的长度都小于64字节
2. 哈希对象保存的元素数量小于512个

否则哈希对象需要使用dict编码。

ziplist的内存结构可以描述为：

```
<zlbytes><zltail><zllen><entry>…<entry><zlend>
```


其中zlbytes占4字节，表示ziplist占用的总字节数；zltail占4字节，表示最后一项在ziplist中的偏移量，方便在尾端直接进行PUSH和POP等操作，zllen占2字节，表示entry的个数；zlend结束符，和前述的EOF一致，值为255。entry是真正存放数据的数据项，有自己独立的内部结构如下：

```
<prevrawlen><len><data>
```

prevrawlen表示前一项数据的总字节数，len表示当前数据项data的长度。这两个长度都是根据实际情况变长编码的，这里不展开描述。

我们使用一个简单的例子来观察RDB对ziplist类型的hash如何存储，并验证这种内存结构。

```
redis>hset me name niexiao
redis>hset me age 18
redis>save
```

执行这几条命令后，生成的ziplist结构如下图：

<img src="ziplist_struct.png" width = "600" height = "400" align=center />

如果hash对象以ziplist类型编码，首先按照当前机器的字节序，取前四个字节zlbytes，计算zset对象整体占据的字节数，然后按照原生字符串的形式，即将当前hash对象在内存中的表示，按字节顺序写入文件。整体结构如下图：
<img src="ziplist_dump.png" width = "600" height = "400" align=center />

上图中按照方框分隔，依次表示的内容为：hash类型以ziplist编码时对应的持久化类型码13；对key的持久化内容长度2+内容'm','e'；ziplist总共占用的字节  数18；剩下的所有内容按照颜色与内存结构图中完全一致。

Dict的结构比较常见，在Redis中的实现结构如下图：
<img src="redis_dict_structure.png" width = "600" height = "400" align=center />

针对Dict的持久化过程比较简单，先写入dict的元素个数，然后再迭代entry，以字符串的方式，将entry.field和entry.value写入文件，不再验证。

##### ZSET

zset对象的编码方式有两种：ziplist和skiplist。那么什么情况下会使用ziplist，什么情况下会使用skiplist呢？

当zset对象同时满足以下两个条件时，对象使用ziplist编码

1. 有序集合保存的元素数量小于128个
2. 有序集合保存的所有元素成员的长度都小于64字节

否则，将使用skiplist编码。

ziplist编码的持久化在hash类型中已经有详细的说明。这里重点看一下对skiplist的持久化。

同样，我们先用个例子回顾下skiplist的结构：

```c
redis>zadd algebra 87.5 Alice
redis>zadd algebra 89.0 Bob
redis>zadd algebra 65.5 Charles
redis>zadd algebra 78.0 David
redis>zadd algebra 93.5 Emily
redis>zadd algebra 87.5 Fred
redis>zadd algebra 95.5 "a long string bigger than 64 bytes"
redis>zrenrangebyscore algebra 94 96    
redis>save
```

执行上述命令后，Redis内部生成的一个跳表可能的结构如下图：
<img src="redis_skiplist_example.png" width = "600" height = "400" align=center />

而对应的RDB dump文件如下：
<img src="skiplist_dump.png" width = "600" height = "400" align=center />

针对skiplist类型value的持久化，整体流程为首先存储整个skiplist的长度，也就是节点个数，然后遍历节点，再依次写入节点内容和得分。需要注意的地方有两点：对skiplist的持久化，value数据是按照跳表节点从后往前存储的。这么做的好处是，有助于提升还原skiplist时候的效率，因为每次插入的都是当前最小值，减少了查找的过程，Redis源码中给出的注释是：

> We save the skiplist elements from the greatest to the smallest (that's trivial since the elements are already ordered in the  skiplist): this improves the load process, since the next loaded element will always be the smaller, so adding to the skiplist will always immediately stop at the head, making the insertion O(1) instead of O(log(N)). 

第二，对于节点内容，按照原生字符串方式进行持久化，而对于double类型的score，并非按照整数类型的编码，而是全部转换为小端后，按照内存布局写入。

##### LIST

Redis中list类型遍量的底层数据结构是quicklist，它是一个双向链表，源码注释中是这样描述的：

> A doubly linked list of ziplists

它确实是一个双向链表，而且是一个ziplist的双向链表。这里不对具体的结构以及涉及到的ziplist节点大小调参等细节做过多描述。还有一个影响持久化的特性是：当列表很长的时候，最容易被访问的很可能是两端的数据，中间的数据被访问的频率比较低（访问起来性能也很低）。如果应用场景符合这个特点，那么list还提供了一个选项，能够把中间的数据节点进行压缩，从而进一步节省内存空间。

<img src="redis_quicklist_structure.png" width = "800" height = "600" align=center />

 有了数据结构的支持，持久化的过程也就很直观了：首先写入quicklist节点中的长度信息，也就是quicklistNode的节点个数。然后从头结点开始遍历，如果不是被压缩过的节点，则直接把上文ziplist的内存结构按原生字符串的方式，写入文件。否则，按照如下lzf压缩格式编码写入。

<img src="lzf压缩.png" width = "600" height = "400" align=center />

##### SET

set对象的编码方式也有两种：intset和dict。当set中添加的元素都是整型且元素数目较少时(512)，set使用intset作为底层数据结构，否则，set使用dict作为底层数据结构。dict格式的持久化在前面已经介绍过了。

这里重点看下intset，它整体结构有header和content两部分组成。Header中encoding指定了content里整数占据的字节数，length指定了整数 的个数，而content的整体长度就是encoding*content。

intset还有一个比较重要的特性是：它所包含的整数元素是按照有序的方式组织，从而便于在上面进行二分查找，用于快速地判断一个元素是否属于这个集合。
<img src="intset.png" width = "600" height = "400" align=center />

针对intset的持久化，由于其在内存上的连续性，所以持久化的时候可以直接按照内存布局，也就是原生字符串的形式写入文件。拿个例子验证下：

```c
redis>sadd score 10
redis>sadd score 5
redis>sadd score 7
redis>sadd score 9
redis>save
```

执行上诉命令后生成的dump文件如下图：
<img src="inset_rdb_dump.png" width = "600" height = "400" align=center />

图中被彩色区域框起来的部分，依次表示：intset的总大小：

```
4byte(encoding)+4byte(length)+2*4 = 16bytes
```

encoding：2，表示每个整数元素使用2字节编码

length: 4，表示总共有4个元素

content: 按照数据元素的大小，从小到大排序依次存储。

#### 如何解决数据存储时的阻塞问题

前面对持久化过程中，不同对象和编码的持久化写入方式和RDB文件结构进行了介绍。那么如何生成RDB文件呢？Redis提供了两个命令来生成RDB文件，SAVE和BGSAVE。

1. SAVE命令会阻塞Redis服务器进程，直到RDB文件创建完毕为止，在服务器进程阻塞期间，不能处理任何命令请求。显然，在线上的应用环境中，这种操作是不被允许的。SAVE只适合在确认影响范围的情况下，手动执行。
2. BGSAVE派生一个子进程，负责处理RDB文件的创建工作，父进程继续处理命令请求。

这里可能会有一个疑问，为什么不在主进程中创建新的线程，而是创建新的子进程来执行RDB的持久化呢？主要是出于Redis性能的考虑，我们知道Redis对客户端响应请求的工作模型是单进程和单线程的，如果在主进程内启动一个线程，这样会造成对数据的竞争条件。所以为了避免使用锁降低性能，Redis选择启动新的子进程，独立拥有一份父进程的内存拷贝，以此为基础执行RDB持久化。

从代码的角度来说，SAVE命令的执行流程如下图：
<img src="rdbSave.png" width = "300" height = "200" align=center />

SAVE的实现过程比较直白，没有太多的逻辑分支，要么全部成功，要么报错。这里隐含了一种"原子性"的概念，因为，rdb的dump文件无论执行多少次SAVE，都只会有一个文件，所以要求要么SAVE成功后，新的dump文件，被更新，要么任何一环出问题，旧的dump文件保持不变。Redis的实现方式就是，利用rename调用，先生成一个临时文件，**并完成刷盘** ，然后使用rename调用对旧的dump文件进行替换。关于rename的原子性可以参考rename的[man page](http://man7.org/linux/man-pages/man2/rename.2.html) 和 [讨论](https://stackoverflow.com/questions/7054844/is-rename-atomic)。

BGSAVE的执行流程如下：

<img src="rdbBgSave.png" width = "500" height = "300" align=center />

1. 如果有正在执行的AOF子进程或者RDB子进程，直接返回失败，防止两个子进程，同时执行大量的磁盘写入，影响效率。
2. 保存执行bgsave时，已修改未持久化的脏数据项个数。
3. 打开一个双向管道，用于后续父子进程的通信。
4. fork出一个子进程。
5. 子进程中首先关闭从父进程继承来的套接字，然后设置进程名称。
6. 子进程调用save执行持久化保存。
7. 如果子进程保存成功，则统计持久化过程中，因copy-on-write机制，生成的脏页内存信息，写日志并通过管道，同步给父进程，用于展示Redis的状态信息时使用(**info** command)。
8. 如果子进程持久化出错，直接退出(使用错误码1)。
9. 父进程首先统计执行fork操作的时间以及内存分配的速率。
10. 如果子进程创建成功，则记录子进程pid和持久化类型；否则，关闭创建的双向管道，设置bgsave的状态为出错。

从bgsave的实现流程不难看出，解决父进程阻塞的问题主要依赖于fork出子进程，独立运行。但是，在实际线上应用场景中，Redis分配的内存都比较大，并且更新很频繁，那么当Copy-On-Write机制出发的内存拷贝过程，会非常消耗资源。参考[bgsave的fork问题](http://www.cnblogs.com/qq78292959/p/3994333.html)

所以，为了尽可能的避免内存脏页的问题，在父进程的最后，选择关闭dict的resize功能，避免出发大量的内存拷贝。

#### 持久化的配置与触发时机

显然，线上应用场景中，持久化功能需要自动的执行，并且是可配置的。Redis允许用户通过设置服务器的save选项，让服务器每隔一段时间自动执行一次BGSAVE命令。save选项的设置可以包含多个条件，只要其中任意一个被满足，服务器就会执行BGSAVE命令。

```c
save 900 1
save 300 10
save 60 10000
```

以上诉配置为例，只要服务器900秒之内进行了至少1次修改，或者300秒之内进行了至少10次修改，或者60秒之内进行了至少10000次修改，都会触发bgsave。

Redis服务器保存此配置的结构体为：

```c
struct saveparam {
    time_t seconds; //秒数
    int changes;    //被修改次数
};
```

Redis的服务器会在内部启动一个定时操作，维护Redis的状态，其中一项工作就是检查saveparam，判断是否需要执行bgsave命令。具体的检查逻辑如下：

```C
 /* Check if a background saving or AOF rewrite in progress terminated. */
    if (server.rdb_child_pid != -1 || server.aof_child_pid != -1 || ldbPendingChildren()) {
        if ((pid = wait3(&statloc,WNOHANG,NULL)) != 0) {
            ...
                
            if (pid == server.rdb_child_pid) {
                backgroundSaveDoneHandler(exitcode,bysignal);
                if (!bysignal && exitcode == 0) 
                    receiveChildInfo();
            }
            
            ...
        }
    }else{
        for (j = 0; j < server.saveparamslen; j++) {
            struct saveparam *sp = server.saveparams+j;

/* Save if we reached the given amount of changes,
* the given amount of seconds, and if the latest bgsave was
* successful or if, in case of an error, at least
* CONFIG_BGSAVE_RETRY_DELAY seconds already elapsed. */
            if (server.dirty >= sp->changes &&
                server.unixtime-server.lastsave > sp->seconds &&
                (server.unixtime-server.lastbgsave_try >
                 CONFIG_BGSAVE_RETRY_DELAY ||
                 server.lastbgsave_status == C_OK))
            {
                serverLog(LL_NOTICE,"%d changes in %d seconds. Saving...",
                    sp->changes, (int)sp->seconds);
                rdbSaveInfo rsi, *rsiptr;
                rsiptr = rdbPopulateSaveInfo(&rsi);
                rdbSaveBackground(server.rdb_filename,rsiptr);
                break;
            }
         }
    }
```

首先检查是否有持久化的子进程未关闭，如果有则对子进程执行后，服务器dirty项，上一次保存时间和是否执行成功等状态进行更新，同时恢复dict的resize功能，并关闭父进程打开的pipe。否则，遍历配置项，检查当前的dirty项和上一次保存到现在的时间差是否满足配置的条件，如果是，则再执行一次bgsave。由于，子进程的持久化可能会失败（比如前面说的fork()拷贝内存过大的问题导致），所以检查条件的时候，如果发现上一次失败了，那么会延迟一段时间，再执行bgsave来消弱这种出错的问题。

### 其他实现细节

Redis对IO操作做了统一的封装，提供了一个抽象的访问接口。根据IO操作媒介的不同，有不同的实现，主要分为Buffer IO，Stdio file pointer IO和File descriptors set IO三种。

核心IO结构体定义如下,  它对不同IO实现所依赖的底层读写接口进行了定义，以union的方式，把IO操作的IO变量组织起来。

```c
struct _rio {
/* Backend functions.
* Since this functions do not tolerate short writes or reads the return
* value is simplified to: zero on error, non zero on complete success. */
    size_t (*read)(struct _rio *, void *buf, size_t len);
    size_t (*write)(struct _rio *, const void *buf, size_t len);
    off_t (*tell)(struct _rio *);
    int (*flush)(struct _rio *);

    void (*update_cksum)(struct _rio *, const void *buf, size_t len);

    /* The current checksum */
    uint64_t cksum;

    /* number of bytes read or written */
    size_t processed_bytes;

    /* maximum single read or write chunk size */
    size_t max_processing_chunk;

    /* Backend-specific vars. */
    union {
        /* In-memory buffer target. */
        struct {
            sds ptr;
            off_t pos;
        } buffer;
        /* Stdio file pointer target. */
        struct {
            FILE *fp;
            off_t buffered; /* Bytes written since last fsync. */
            off_t autosync; /* fsync after 'autosync' bytes written. */
        } file;
        /* Multiple FDs target (used to write to N sockets). */
        struct {
            int *fds;       /* File descriptors. */
            int *state;     /* Error state of each fd. 0 (if ok) or errno. */
            int numfds;
            off_t pos;
            sds buf;
        } fdset;
    } io;
};
```

 RDB持久化的文件写入，就是基于文件的IO实现:

```c
static const rio rioFileIO = {
    rioFileRead,   /*基于文件读写接口的读写实现*/
    rioFileWrite,
    rioFileTell,
    rioFileFlush,
    NULL,           /* update_checksum */
    0,              /* current checksum */
    0,              /* bytes read or written */
    0,              /* read/write chunk size */
    { { NULL, 0 } } /* union for io-specific vars */
};
```

这种高度抽象的代码实现方式，不仅通用而且精简了代码，值得学习~

### 参考文献

1. [redis-ziplist](http://zhangtielei.com/posts/blog-redis-ziplist.html)

2. [redis-intset](http://zhangtielei.com/posts/blog-redis-intset.html)

3. [redis-skiplist](http://zhangtielei.com/posts/blog-redis-skiplist.html)

4. [redis-dict](http://zhangtielei.com/posts/blog-redis-dict.html)

5. [redis-object](https://www.cnblogs.com/paulversion/p/8206080.html)

6. 《Redis设计与实现》 黄健宏著


