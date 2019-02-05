---
title: Mysql存储机制-数据页管理
toc: false
thumbnail: /images/armour.jpg
date: 2018-11-13 16:40:52
author: NX
tags: MySQL
categories: 存储
---

Mysql中，索引即数据。Index page是数据表中一条条数据和索引的载体，是最重要的一种页面类型。本章讨论和验证了索引页的物理存储结构

<!-- more -->


## Page structure

Index page的物理视图如下图所示。除去通用的页面头部`FIL Header`和`Tailer`，页面体主要包含三个部分：`Index Page Header`,`Records Space`,`Record Directory`。`Index Page Header`是Index Page特有的页头，`Record Space`是用户记录空间，包括已使用和空闲空间两部分，`Record Directory`是一个稀疏索引，主要用于加速rec在页内的查询速度。

<img src="index page.jpg" width = "600" height = "400" align=center title="index page" />

### Index Page Header

Index Page Header是索引页独有的信息，其中各字段(红色部分)所包含的信息说明如下表：

|      Macro       | Bytes |                             Desc                             |
| :--------------: | :---: | :----------------------------------------------------------: |
| PAGE_N_DIR_SLOTS |   2   |                  Page directory中的slot个数                  |
|  PAGE_HEAP_TOP   |   2   |   当前Page内已使用的空间的末尾位置，即free space的开始位置   |
|   PAGE_N_HEAP    |   2   | Page内所有记录个数，包含用户记录，系统记录以及标记删除的记录，同时当第一个bit设置为1时，表示这个page内是以Compact格式存储的 |
|    PAGE_FREE     |   2   |              指向标记删除的记录链表的第一个记录              |
|   PAGE_GARBAGE   |   2   | 被删除的记录链表上占用的总的字节数，属于可回收的垃圾碎片空间 |
| PAGE_LAST_INSERT |   2   |    指向最近一次插入的记录偏移量，主要用于优化顺序插入操作    |
|  PAGE_DIRECTION  |   2   | 用于指示当前记录的插入顺序以及是否正在进行顺序插入，每次插入时，PAGE_LAST_INSERT会和当前记录进行比较，以确认插入方向，据此进行插入优化 |
| PAGE_N_DIRECTION |   2   |               当前以相同方向的顺序插入记录个数               |
|   PAGE_N_RECS    |   2   |            Page上有效的未被标记删除的用户记录个数            |
| PAGE_MAX_TRX_ID  |   8   | 最近一次修改该page记录的事务ID，主要用于辅助判断二级索引记录的可见性。 |
|    PAGE_LEVEL    |   2   | 该Page所在的btree level，根节点的level最大，叶子节点的level为0 |
|  PAGE_INDEX_ID   |   8   |                      该Page归属的索引ID                      |
|                  |       |                                                              |

除去红色部分的索引头之外，索引的根节点root page还记录中间节点段和叶子节点段的信息，称为FSEG Header：

| Macro             | Bytes | Desc                                 |
| ----------------- | ----- | ------------------------------------ |
| PAGE_BTR_SEG_LEAF | 10    | leaf segment在inode page中的位置     |
| PAGE_BTR_SEG_TOP  | 10    | non-leaf segment在inode page中的位置 |

### Record Space

用户记录（后简称rec）组织方式采用的是按键值有序的单向链表方式来组织的。Record Space空间中，最前面两条记录永远是：infimum 和 supremum这两条，分别用来标记虚拟的最前面一个记录和最后面一个记录。

Mysql中rec是可变长的，包含record header和record data两部分。Innodb引擎中，对rec支持不同的编码格式，接下来将会以Compact模式为例介绍聚簇索引和非聚簇索引的叶子节点和中间节点的物理结构。在此之前，先声明一个定义：Innodb引擎中，把record data的起始地址称为‘origin’，使用N表示，record header使用负偏移量，如N-2来表示。

#### The record header

record header的结构如下图。

<img src="Record Format-Header.png" width = "600" height = "400" align=center title="Record Format - Header" />

自底向前看，各部分的含义为：

+ Next Record Offset，2字节，该页面中，当前记录按主键升序排列的下一条记录的页内偏移量
+ Record Type，rec的类型，可选值包括：用户数据conventional(0)，索引数据node pointer(1)，infimum(2)以及supermum(3)
+ Order/Heap no，用户记录在page中按插入顺序对应的物理编号，infimum始终取0，supremum始终取1，用户记录从2开始计数
+ Number of Records Owned，当该值为非0时，表示当前记录占用page directory里一个slot，并和前一个slot之间存在这么多个记录。
+ Info Flags，标记位，目前只使用了两个bit，一个用于表示该记录是否被标记删除(`REC_INFO_DELETED_FLAG`)，另一个bit(REC_INFO_MIN_REC_FLAG)如果被设置，表示这个记录是当前level最左边的page的第一个用户记录，即最小的记录。
+ Nullable field bitmap，可选，标示值为NULL的列的bitmap，每个位标示一个列，如果一个列为空，在rec data中不存储任何值，只在这里mark
+ Variable field length array，可选，记录可变长列的长度数组。如果列的最大长度为255字节，使用1byte；否则，0xxxxxxx (one byte, length=0..127), or 1exxxxxxxxxxxxxx (two bytes, length=128..16383, extern storage flag)

#### Clustered Indexes

聚簇索引下叶子节点中记录的结构如下图

<img src="Record Clustered Leaf.png" width = "600" height = "400" align=center title="Record Clustered Leaf" />

从rec data的起始位置开始，依次包含以下字段：

+ Cluster Key Fields，索引字段，以字节流的形式依次拼接索引字段
+ Transaction ID，事务id，6字节，上次修改当前记录的事务id
+ Roll Pointer，回滚指针，上一次修改当前记录的事务在回滚段中的回滚记录的位置
+ Non-Key Fields，非索引字段，以字节流形式依次拼接的所有非索引字段

聚簇索引下非叶子节点中记录的结构相比于叶子节点要简单很多：首先，由于非叶子节点不支持MVCC，所以记录中不包含事务和回滚指针；其次，由于索引字段不能为空，所以rec header和rec data中都不包含Non-Key Fields。具体结构如下图。

<img src="Record Clustered Non-Leaf.png" width = "600" height = "400" align=center title="Record Clustered Non-Leaf" />

从rec data的起始位置开始，依次包含以下字段：

+ 当前记录所对应的叶子节点中按主键排序最小的主键值
+ 叶子节点的页号

#### Secondary Indexes

非聚簇索引（后简称二级索引）的叶子节点结构和聚簇索引类似，除去少了事务ID和回滚指针外，大体类似。需要特别指出的是，如果二级索引字段和聚簇索引字段有重叠，那么重叠的部分将被记录在Secondary Key Fields中。比如：一张表包含聚簇索引（a,b,c）和二级索引（a,d），那么，Secondary Key Fields将包含a,d, Cluster Key Fields将只包含（b,c）。结构如下图：

<img src="Record Secondary Leaf.png" width = "600" height = "400" align=center title="Record Secondary Leaf" />

非聚簇索引的非叶子节点结构如下图，与聚簇索引类似，不再赘述。

<img src="Record Secondary Non-Leaf.png" width = "600" height = "400" align=center title="Record Secondary Non-Leaf" />

### Directory

由于rec在page内是按照主键升序的单链表形式组织的，如果不使用任何辅助结构，那么在page内检索一条记录就需要从infimum开始，依次比对，效率不高。为了加快页内的数据查找，会按照记录的顺序，每隔4~8个数量的用户记录，就分配一个slot 。每个slot占用2个字节，存储记录的页内偏移量，可以理解为在页内构建的一个很小的索引(sparse index)来辅助二分查找。

Page Directory的slot分配是从Page末尾（倒数第八个字节开始）开始逆序分配的。在查询记录时。先根据Page directory 确定记录所在的范围，然后在据此进行线性查询。
