---
title: 一条order by排序语句执行过程
toc: true
thumbnail: /images/1.jpeg
date: 2019-02-09 20:12:33
author:
tags:
---
MySQL做排序是一个成本比较高的操作。本文整理了MySQL是怎么做order by排序的。
<!--more-->
假设一个表:
```sql
CREATE TABLE `t` (
  `id` int(11) NOT NULL,
  `city` varchar(16) NOT NULL,
  `name` varchar(16) NOT NULL,
  `age` int(11) NOT NULL,
  `addr` varchar(128) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `city` (`city`)
) ENGINE=InnoDB;
```
想要查询城市是“杭州”的所有人名字，并且按照姓名排序返回前1000个人的姓名、年龄。业务语句: 
```sql
select city,name,age from t where city='杭州' order by name limit 1000  ;
```
<img src="orderby1.png" width = "600" height = "300" alt="" align= />

## 无序数据
MySQL会给每个线程分配一块**内存**用于排序，称为sort_buffer。
city 索引的示意图：
<img src="orderby2.png" width = "600" height = "300" alt="" align= />
### 查询字段不多 - 全字段排序
语句执行流程：
1. 初始化sort_buffer,确定放入name, city, age 这三个字段；
2. 从索引city找到第一个满足city = “杭州”条件的主键id, 也就是图中ID_X;
3. 到主键id索引去取出整行，取name, city, age三个字段的值，存入sort_buffer中；
4. 从索引city取下一个记录的主键id;
5. 重复3，4直到city的值不满足查询条件为止，对应的主键id也就是途中ID_Y；
6. 对sort_buffer中的数据按照字段name做快速排序；
7. 按照排序结果取前1000行返回给客户端。

按name排序可以在内存中完成，也可能需要使用外部排序，这取决于**排序所需要的内存和参数sort_buffer_size**。sort_buffer_size即为MySQL为排序开辟的内存sort buffer的大小。
- 如果要排序的数据小于sort_buffer_size, 排序就在内存中完成；
- 如果排序数据量太大，内存放不下，就得利用**磁盘的临时文件**进行辅助外部排序。外部排序一般使用**归并排序算法**。MySQL将需要排序的文件分成X份，每一份单独排序后存在这些临时文件中。然后把这X个有序文件再合并成一个有序的大文件。另外MySQL 5.6以后进行了优化，对于`limit n, n<sort_buffer_size`的排序会使用**优先队列排序（堆排序）**，不需要临时文件。

### 查询字段多 - row id 排序
如果查询要返回的字段很多的话，那么sort_buffer里面要放的字段太多，这样内存里能够同时放下的行数很少。如果要分成很多个临时文件，排序的性能会很差。

当查询字段多，MySQL为了避免分成多个临时文件排序性能差，会放弃使用全字段排序，选择row id排序：
语句执行流程：
1. 初始化sort_buffer, 确定放入两个字段，即name和id;
2. 从索引city找到第一个满足city=“杭州”条件的主键id, 也就是图中的ID_X;
3. 到主键id索引取整行，取name, id 这两个字段，存入sort_buffer中；
4. 从索引city取下一个记录的主键id;
5. 重复3，4直到city的值不满足查询条件为止，对应的主键id也就是途中ID_Y；
6.  对sort_buffer中的数据按照字段name做快速排序；
7.  遍历排序结果，取前1000行，并按照id值**回表**中取出city、name和age三个字段返回给客户端。

对比全字段排序，row id排序多了回表。这种排序方式只有MySQL查询字段多导致内存不足才会使用。

## 有序数据排序 - 并不需要成本高地去排序
如果增加覆盖索引
```sql
alter table t add index city_user(city, name, age);
```
执行流程：
1. 从索引（city, name, age）找到第一个满足city='杭州'条件的记录，取出其中city, name和age这三个字段的值，作为结果集的一部分直接返回；
2. 从索引 (city,name,age) 取下一个记录，同样取出这三个字段的值，作为结果集的一部分直接返回；
3. 重复执行步骤 2，直到查到第 1000 条记录，或者是不满足 city='杭州’条件时循环结束。

<img src="orderby4.png" width = "600" height = "300" alt="" align= />
可以看出extra字段没有using filesort--不需要排序。也使用到了覆盖索引，性能会快很多。
## 深分页问题解决方法

## 随机排序
> 从一个单词表随机选出三个单词。

```sql
mysql> CREATE TABLE `words` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `word` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB;
```

### order by rand()
```sql
mysql> select word from words order by rand() limit 3;

```

`tmp_table_size`这个配置限制了内存临时表的大小，默认值是16M。如果临时表大小超过了tmp_table_size, 那么内存临时表就会转成磁盘临时表。
- 使用内存临时表
内存临时表排序使用rowid排序方法。
- 使用磁盘临时表
当使用磁盘临时表的时候，对应的就是一个没有显示索引的InnoDB表的排序过程。

无论使用哪种类型的临时表，order by rand()这种写法都会让计算过程非常复杂 - 需要大量的扫描行数，整个表排序、

### 一种更好的方案
1. 取得这个表的主键id的最大值M和最小值N；
2. 用随机函数生成一个最大值和最小值之间的数 X = （M-N）\* rand() + N;
3. 取不小于X的第一个ID的行

## 参考
[极客时间](https://time.geekbang.org/column/article/73479)
