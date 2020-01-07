---
title: 关于MySQL的临时表和临时文件
toc: false
thumbnail: /images/sorth.jpeg
date: 2019-12-03 14:34:34
author: GSM
tags: MySQL
categories: 学习积累
article-thumbnail: false
---
本文为学习摘抄。
<!--more-->
# 临时表
临时表可以分为磁盘临时表和内存临时表，而临时文件只会存在于磁盘上，不会在内存上。
临时表当tmp_table_size小于一定值时候都是内存表 -- 临时表的内存形态有Memory 引擎和Temptable引擎，主要区别是对字符类型(varchar, blob，text类型)的存储方式，前者不管实际字符多少，都是用定长的空间存储，后者会用变长的空间存储，这样提高了内存中的存储效率，有更多的数据可以放在内存中处理而不是转换成磁盘临时表。Memory引擎从早期的5.6就可以使用，Temptable是8.0引入的新的引擎。

当超过tmp_table_size -- 内存临时表就转成磁盘临时表，磁盘临时表有三种形态。一种是MyISAM表，一种是InnoDB临时表，另外一种是Temptable的文件map表。其中最后一种方式，是8.0提供的。

目前有两种情况会用到临时表：
1. 用户显示创建临时表，这种直接创建磁盘文件。
```
create temporary table
```
2. 优化器隐式创建临时表
这种临时表，是数据库为了辅助某些复杂的SQL的执行而创建的辅助表，是否需要临时表，一般都是由优化器决定。与用户显式创建的临时表直接创建磁盘文件不同，如果需要优化器觉得SQL需要临时表辅助，会先使用内存临时表，如果超过配置的内存(min(tmp_table_size, max_heap_table_siz))，就会转化成磁盘临时表，这种磁盘临时表就类似用户显式创建的，引擎类型我们是InnoDB。一般稍微复杂一点的查询，包括且不限于order by, group by, distinct等，都会用到这种隐式创建的临时表。用户可以通过explain命令，在Extra列中，看是否有Using temporary这样的字样，如果有，就肯定要用临时表。


# 临时文件
临时文件更多的呗使用在缓存数据，排序数据的场景。一般情况下，被缓存或者排序的数据，首先放在内存，如果内存不足（超过sort_buffer_size），才会使用磁盘临时文件的方式。

另外explain是看不出是否使用了临时文件，只能通过查看 OPTIMIZER_TRACE 的结果来确认的，你可以从 number_of_tmp_files 中看到是否使用了临时文件。

# 参考
[taobao数据库内核月报](http://mysql.taobao.org/monthly/2019/04/01/)
