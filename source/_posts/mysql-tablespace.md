---
title: Mysql存储机制—表空间结构
toc: false
thumbnail: /images/kafka1025.jpeg
date: 2018-11-13 16:20:53
author: NX
tags: MySQL
categories: 学习积累
---

本文基于InnDB存储引擎源码，试图解释Mysql数据表在InnoDB引擎下的组织管理方式。本文重点对用户表空间的物理和逻辑结构进行阐述，属于Mysql存储机制系列之一。

InnoDB引擎对Mysql数据的管理，在物理层表示上（即磁盘实际存储的文件），包括日志文件、主系统表空间文件ibdata、undo tablespace文件、临时表空间文件以及用户表空间。这些文件具有统一的结构，本文以用户表空间为例，进行展开。

<!-- more -->

## 概述

InnoDB 的每个数据文件都归属于一个表空间，不同的表空间使用一个唯一标识的space id来标记。例如ibdata1, ibdata2… 归属系统表空间，拥有相同的space id。用户创建表产生的ibd文件，则认为是一个独立的tablespace，只包含一个文件。

InnoDB引擎对表空间在内部的逻辑视图如下：

<img src="LogicOverview.png" width = "600" height = "400" align=center title="LogicOverview" />

1、表空间

+ 默认情况下，只有一个表空间ibdata1，所有数据存放在这个空间内
- 如果启用了innodb_file_per_table，则每张表内的数据可以单独放到一个表空间内
- 每个表空间只存放数据、索引和InsertBuffer Bitmap页，其他数据还在ibdata1中

2、Segment段（InnoDB引擎自己控制）

- 数据段：B+ tree的叶子节点
- 索引段：B+ tree的非叶子节点
- 回滚段

3、extent区

- 每个区的大小为1M，页大小为16KB，即一个区一共有64个连续的页（区的大小不可调节，页可以）

4、Page页

- InnoDB磁盘管理的最小单位
- 默认每个页大小为16KB，可以通过innodb_page_size来设置（4/8/16K）
- 每个页最多存放7992行数据
- 页有不同的类型，如果表空间管理页，INODE节点页，插入缓存页以及存放数据的索引页等

5、Row行

+ 对应数据表里一条条记录，后续单独对页内数据组织方式进行说明

InnoDB引擎对表空间组织的物理视图如下：

<img src="Phsical Overview.jpg" width = "600" height = "400" align=center title="Phsical Overview" />


接下来将对上图中的Page内容和组织管理方式进行逐一说明。

## File Header

InnoDB磁盘管理的最小单位是页，所有页都有两个统一的结构：页头（FIL Header），占据页面的前38个字节；页尾（FIL Trailer），占据页面末尾8字节。

### FIL Header

页头包含的数据项如下：

|          Macro           | Offset | description                                |
| :----------------------: | ------ | ------------------------------------------ |
| FIL_PAGE_SPACE_OR_CHKSUM | 0      | 4.0.14版本前，表示space id; 之后表示校验和 |
|     FIL_PAGE_OFFSET      | 4      | 当前页的偏移量（Page no）                  |
|      FIL_PAGE_PREV       | 8      | 前驱节点的偏移量                           |
|      FIL_PAGE_NEXT       | 12     | 后继节点的偏移量                           |
|       FIL_PAGE_LSN       | 16     | 最近一次修改该page的LSN                    |
|      FIL_PAGE_TYPE       | 24     | 页面类型                                   |
| FIL_PAGE_FILE_FLUSH_LSN  | 26     | Checkpoint for system tablespace           |
|    FIL_PAGE_SPACE_ID     | 34     | space id                                   |

`FIL_PAGE_OFFSET`表示当前页在其表空间中的相对偏移量，也就是页号。`FIL_PAGE_TYPE`表示当前页的类型，常用的页面类型如下表：

|          MACRO          | VALUE |      DESCRIPTION       |
| :---------------------: | :---: | :--------------------: |
|     FIL_PAGE_INDEX      | 17855 |      B-tree索引页      |
| FIL_PAGE_TYPE_ALLOCATED |   0   |  磁盘新分配未使用的页  |
|    FIL_PAGE_UNDO_LOG    |   2   |       Undo log页       |
|     FIL_PAGE_INODE      |   3   |        INODE页         |
|    FIL_PAGE_TYPE_SYS    |   6   |         系统页         |
|  FIL_PAGE_TYPE_FSP_HDR  |   8   | file space header page |
|   FIL_PAGE_TYPE_XDES    |   9   |    extent desc page    |
|   FIL_PAGE_TYPE_BLOB    |  10   |     未压缩的BLOB页     |

InnoDB引擎中，索引B-tree上，在同一Level的索引页会按照双向链表的方式组织起来，`FIL_PAGE_PREV`，`FIL_PAGE_NEXT`则提供了一个索引页的前驱和后继节点的页号。需要指出的是，BLOB类型的页面是按照单链表的方式组织，不存在`FIL_PAGE_PREV`结构。`FIL_PAGE_INODE`页记录Segment的组织信息，一个Segment对应页内一条Inode Entry。

### FIL Trailer

 page trailer是在文件末尾的最后8个字节， 低位4个字节是用来表示page页中数据的checksum,高位4位是用来存储FIL_PAGE_LSN的部分信息。

## File Space Header Page

参考上文的物理视图，表空间第一页的类型总是为`FIL_PAGE_TYPE_FSP_HDR`，负责记录整个表空间的使用情况和标志位的状态信息。页面中，紧跟着通用页头FIL Header的是**File Space Header**结构，共112字节。

接着，每个XDES entry结构40个字节，描述一个extent的使用情况。一个File Space Header Page内最多包含256个XDES entry，即该page同时用于跟踪随后的256个extent(约256MB文件大小)的空间管理，所以每隔256MB就要创建一个类似的数据页，类型为`FIL_PAGE_TYPE_XDES`，XDES Page除了**File Space Header**结构全填0之外，其他都和`FIL_PAGE_TYPE_FSP_HDR`页具有相同的数据结构，可以称之为extent描述页。

### File Space Header

**File Space Header** 的结构如下表：

|        Macro        | OFFSet | DESCRIPTIon                                                  |
| :-----------------: | ------ | ------------------------------------------------------------ |
|    FSP_SPACE_ID     | 0      | space id                                                     |
|    FSP_NOT_USED     | 4      | 保留字段                                                     |
|      FSP_SIZE       | 8      | 当前表空间的页面总数                                         |
|   FSP_FREE_LIMIT    | 12     | 当前未初始化的最小Page no                                    |
|   FSP_SPACE_FLAGS   | 16     | 标志位信息                                                   |
|   FSP_FRAG_N_USED   | 20     | FSP_FREE_FRAG链表上已被使用的Page数，用于快速计算该链表上可用空闲Page数 |
|      FSP_FREE       | 24     | 所有page都没有被使用的extent链表                             |
|    FSP_FREE_FRAG    | 40     | 有可分配的page的extent链表                                   |
|    FSP_FULL_FRAG    | 56     | 所有page均已被分配的extent链表                               |
|     FSP_SEG_ID      | 72     | 新生成段的id（current max seg id +1）                        |
| FSP_SEG_INODES_FULL | 80     | 已被完全用满的Inode Page链表                                 |
| FSP_SEG_INODES_FREE | 96     | 至少存在一个空闲Inode Entry的Inode Page被放到该链表上        |

`FSP_FREE_LIMIT`记录当前未初始化的最小Page no，随着数据表的持续写入，表空间也在不断增长，InnoDB引擎需要对当前的存储文件进行扩展（涉及磁盘IO操作），为了减少扩展的次数，每次回多预留一些空间，这些未被纳入管理的剩余页面，就是通过FSP_FREE_LIMIT来标识。`FSP_FREE`，`FSP_FREE_FRAG`，`FSP_FULL_FRAG`三个字段根据**整个表空间**中extent（包括当前File Space Header Page所能管理的256个extent之外的所有extent）的使用情况，划分为三个链表进行维护。`FSP_SEG_INODES_FULL`，`FSP_SEG_INODES_FREE`两个字段根据Inode page页的使用情况，划分为已填满和可分配两个链表进行管理

### List Node

为了管理Page，Extent这些数据块，在文件中记录了许多的节点以维持具有某些特征的链表，例如在在文件头维护的inode page链表，空闲、用满以及碎片化的Extent链表等等。

由于这些链表节点信息都是写在实际磁盘上的，所以与常用的基于结构体和内存指针组成的内存链表不同，文件链表存储的地址信息则是通过4bytes的页号和2byte的页内偏移量组成的。

在InnoDB里链表头称为`FLST_BASE_NODE`，其结构如下表：

|   Macro    | bytes |      desc      |
| :--------: | :---: | :------------: |
|  FLST_LEN  |   4   |    列表长度    |
| FLST_FIRST |   6   | 列表首节点地址 |
| FLST_LAST  |   6   | 列表尾节点地址 |

BASE NODE维护了链表的头指针和末尾指针，每个节点称为`FLST_NODE`，结构如下表：

|   Macro   | bytes |     desc     |
| :-------: | :---: | :----------: |
| FLST_PREV |   6   | 前驱节点地址 |
| FLST_NEXT |   6   | 后继节点地址 |

类似的，InnoDB引擎内部（内存中）对各种内存链表的结构也做了统一的封装，其基本结构与文件链表相同，具体代码实现如下：

```c
template <typename TYPE>
struct ut_list_base {
	typedef TYPE elem_type;

	ulint	count;/*!< count of nodes in list */
	TYPE*	start;/*!< pointer to list start, NULL if empty */
	TYPE*	end;/*!< pointer to list end, NULL if empty */
};

template <typename TYPE>
struct ut_list_node {
	TYPE* 	prev;	/*!< pointer to the previous node,
			NULL if start of list */
	TYPE* 	next;	/*!< pointer to next node, NULL if end of list */
};
```

基础节点(base node)包含了链表的长度和首位指针信息。普通的元素节点则只包含前驱后继节点的信息。

### XDES Entry

**XDES Entry** 结构描述了一个extent内部所有page的使用情况(默认64page)。其结构如下表：

|     macro      | offset |             DESC             |
| :------------: | :----: | :--------------------------: |
|    XDES_ID     |   0    |    extent所属的segment id    |
| XDES_FLST_NODE |   8    | 维持Extent链表的双向指针节点 |
|   XDES_STATE   |   20   |       extent的使用状态       |
|  XDES_BITMAP   |   32   |    维护page使用情况的位图    |

`XDES_STATE`可能取值的状态为：

|     MAcro      | VALUE |                desc                |
| :------------: | :---: | :--------------------------------: |
|   XDES_FREE    |   1   |   分区在file space的free list上    |
| XDES_FREE_FRAG |   2   | 在file space的free fragment list上 |
| XDES_FULL_FRAG |   3   | 在file space的full fragmentlist上  |
|   XDES_FSEG    |   4   |    该extent在XDES_ID的SEGMENT上    |

通过`XDES_STATE`信息，我们只需要一个`FLIST_NODE`节点就可以维护每个extent的信息，是处于全局表空间的链表上，还是某个btree segment的链表上。

`XDES_BITMAP`中每一个page占两位，共64*2=128bit，其中一位`XDES_FREE_BIT`表示当前page的使用情况，另外一位`XDES_CLEAN_BIT`暂未使用。

## Insert Buffer Page

插入缓存页，暂不深入讨论。

## Inode Page

InnoDB使用Inode Page来维护段（**Segment**）的使用信息，一般idb文件系统空间的第三页就是Inode Page。数据即索引，在创建一个b-tree索引时，默认生成2个segment，分别用于管理b-tree的中间节点和叶子节点。

Inode Page的内部组织方式如上述物理视图，出去页面通用页头和页尾之外，主要包含两个部分：Inode entry list和Inode page list。

### Inode Entry

每个Inode Entry描述了一个段内的extent以及page的使用情况，具体的结构如下：

|        Macro         | offset  |                  desc                   |
| :------------------: | :-----: | :-------------------------------------: |
|       FSEG_ID        |    0    |         Segment id(0表示未使用)         |
| FSEG_NOT_FULL_N_USED |    8    |  FSEG_NOT_FULL链表上已被使用的Page数量  |
|      FSEG_FREE       |   12    | 分配给该Segment完全且未使用的extent链表 |
|    FSEG_NOT_FULL     |   28    |          部分可用的extent链表           |
|      FSEG_FULL       |   44    |          已使用完的extent链表           |
|     FSEG_MAGIC_N     |   60    |                  魔数                   |
|   FSEG_FRAG_ARR[0]   |   64    |            碎页数组首页地址             |
|         ...          |   ...   |                   ...                   |
|  FSEG_FRAG_ARR[31]   | 64+32*4 |            碎页数组尾页地址             |

除了维持当前segment下的extent链表外，为了节省内存，减少碎页，每个Entry还占有32个独立的page用于分配，每次分配时总是先分配独立的Page，当填满32个数组项时，再在每次分配时都分配一个完整的Extent，并在XDES PAGE中将其Segment ID设置为当前的段id。

### Page List

一个Innode page里最多存放85个entry，对于idb文件来说，除去回滚段之外，只有索引段，除非为一张表申请42个索引，否则一个Innode page足够使用。而如果未开启`innodb_file_per_table`选项的数据库来说，所有的信息都存储在ibdata文件，可能需要多个Inode page来维护段信息。Innodb将这些Inode page通过链表的方式组织起来，在页头之后存储了链表的base节点，具体可以参考**List Node**一节对通用链表结构的描述，此处不再详述。


## 总结

本文以idb文件为切入点，介绍了Innodb引擎对底层文件的组织方式。在idb文件中，除去实际存储数据和索引节点信息的Index Page之外（后续介绍页内组织方式的时候详细阐述），其他类型的page都做了简要的介绍，各页面之间相互索引和定位的组织方式如下图：

<img src="space file organized.jpg" width = "600" height = "400" align=center title="space file organized" />

自底向上来看，第一页Page0对应File space header页，其内部的256个entry数组，记录了前256个extent的使用情况。第二页Page1是插入缓存页。第三页Page2是Inode Page，其内部的每一个entry，记录了当前段内个分区的使用情况，以链表的方式组织起来，此外还各自单独占据了一部分独立的Page用于分配。第四页是在我们创建索引后，为根节点独立分配的一个root page，其中记录了中间节点段和叶子节点段的地址信息。

## 参考文献

1. [MySQL · 引擎特性 · InnoDB 文件系统之文件物理结构](https://blog.csdn.net/mysql_lover/article/details/54612876)
2. [MySQL系列：innodb源码分析之表空间管理](https://blog.csdn.net/yuanrxdu/article/details/41925279)
3. [The physical structure of InnoDB index pages](https://blog.jcole.us/2013/01/07/the-physical-structure-of-innodb-index-pages/)
