---
title: MySQL的锁
toc: true
thumbnail: /images/mysql-lock.png
date: 2019-03-01 10:16:28
author: GSM
tags:
---
时不时就要来翻翻看。
<!--more-->
# 锁的使用场景
在多用户环境中，同一时间可能会有多个用户同时更新相同记录，这就会产生冲突 - 并发性问题。典型的冲突有：
- 丢失更新：一个事务的更新覆盖了其他事务的更新结果，就是所谓的丢失更新：例如用户A把值从6改为2， 用户B把值从2改为6，则用户A丢失了他的更新。
- 脏读，脏读又称无效数据的读出，是指在数据库访问中，事务T1将某一值修改，然后事务T2读取该值，此后T1因为某种原因撤销对该值的修改，这就导致了T2所读取到的数据是无效的。 脏读就是指当一个事务正在访问数据，并且对数据进行了修改，而这种修改还没有提交到数据库中，这时，另外一个事务也访问这个数据，然后使用了这个数据。

为了解决并发的冲突问题，需要引入并发控制机制。而并发控制机制最常用的办法就是加锁。当一个用户锁住数据库中的某个对象时，其他用户就不能再访问该对象。加锁对并发访问的影响体现在锁的粒度上。

# 全局锁
一句话特点：InnoDB不用，MyISAM才用。

MySQL提供的针对数据库级别的对数据加读锁的功能:Flush tables with read lock（FTWRL）。之后针对这个数据库的增删改、DDL、事物提交语句都会被堵塞住。他主要的用途是用于数据库全库的逻辑备份.

【优点】
全局锁是数据库级别的，所有表引擎都支持，在数据的导出对库实例加锁，保持导出数据逻辑的一致性。和设置数据库只读（set global readonly=true）相比，全局锁在当前链接异常或者中断的情况下可以自动释放，而设置数据库只读不能。
注：对于Innodb引擎，我们推荐用使用mysql自带的mysqldump工具，并且使用参数–single-transaction.( 导数据之前就会启动一个事务，来确保拿到一致性视图。而由于MVCC的支持，这个过程中，数据是可以正常更新的。这样就不需要全局锁，但是只适用于InnoDb引擎)。如果表不支持MVCC，我们还是只能利用全局锁。

# 表级锁
MySQL的表级锁分俩种，一种是表锁，一种是元数据锁（meta data lock MDL）

## 表锁
语法是 lock tables ... read/write。可以用unlock主动释放锁。也可以在链接中断时候自动释放。
表锁对于自己和其他线程读写操作的限制如下：如果对一个表进行read/write锁。其他线程在写or读/写时都会堵塞；同时本线程也只能读or读写该表，其他表无法访问。

缺陷：锁的粒度太大导致影响面大。

使用场景：在还没有出现更细粒度的锁的时候，表锁是最常用的处理并发的方式（MyISAM）。而对于InnoDB这种支持行锁的引擎，一般不使用lock tables命令控制并发。

## 元数据锁（MDL）
该锁不会显式的使用，在访问表的时候会自动加上，他用来保护数据字典元数据，保证在并发情况下，结构变更的一致性。

```
结构变更的一致性 ：读写正确性是针对DDL操作来说的，保证多线程读写DB的操作中，
任何线程都能读到最新的表结构的数据。

举个例子来说：
如果一个查询正在遍历一个表中的数据，而执行期间另一个线程对这个表结构做变更，
删了一列，那么查询线程拿到的结果跟表结构对不上，肯定不行的。
```

原理上MDL锁的加锁模式是：mutex + condition + queue来实现类似公平锁的并发阻塞唤醒机制。DDL语句发起时候，如果无法获取排他锁，那么DDL将进入阻塞状态，但是由于阻塞队列的设计，就阻塞了后面所有的DML和SELECT操作，在高并发系统上，有可能引起雪崩。

他有如下特点：

- 对一个表的数据CRUD时候，加MDL读锁；当修改表结构时候，加MDL写锁
- 读锁是不互斥的，因为这些操作不会改表结构，所以可以多个线程同时对表做CRUD；
- 读写锁之间，写锁之间是互斥的，也就是说当对表进行CRUD时候，为了保证返回数据的读写的正确性，DDL操作是堵塞的。

这也是为什么公司RDS不允许高峰期提工单执行DDL的原因之一。

另外由于上面MDL的读写锁机制，就会有下面这种情况，修改一个访问量很高的小表，会导致整个库挂掉：比如: 大量的select语句，加了MDL读锁，这时候是不会堵塞的;这时候有一条alter表的语句需要执行，加了MDL写锁，开始block。由于select量很大，alter会一直堵塞，这时候后续的select也会堵塞，很块连接池就被用完了。

解决方法：
1.首先解决长事务，事务不提交就会一直占着MDL锁。在MySQL中找到正在执行的事务，kill掉长事务。
2.如果是变更的表是热点表，虽然数据量不大，但是请求频繁，在加字段的时候处理办法只能为：给alter table语句里面设置等待时间，如果能在指定等待时间内拿到MDL写锁最好，拿不到也不阻塞后面语句，先放弃。MariaDB&AliSQL解决了这个问题。

# 行锁
MySQL不显示指定行锁，都是InnoDB自动加的。MyISAM没有行锁，这也是逐渐MyISAM被互联网抛弃的原因。

Innodb的行锁定分为两种类型，共享锁-S锁和排他锁-X锁。而在锁定机制的实现过程中，为了让行级锁定和表级锁定共存，InnoDB也同样使用了意向锁（表级锁定）的概念，也就有了意向共享锁和意向排他锁两种。

另外，对于insert,update,delete, Innodb会自动给涉及的数据加X锁；对于一般的select语句，innodb不会加任何锁，事务可以通过语句给显式加共享锁或者排他锁；对于alter操作会锁表：

## 行锁的两阶段性
为了加强数据库的并发度引入的锁的机制，他有如下几个特点：

- 行锁是由MySQL的引擎决定，Innodb支持行锁，MyISAM不支持行锁。
- Innodb的行锁是两阶段锁：即数据需要锁的时候对数据涉及到的行加锁；在事务结束后才释放行锁；

为了减少锁的冲突，我们在事务中要把会引起锁冲突的语句往后放。因为事务是原子性的所以，在一个事务中，要么都成功要么都失败，所以我们在一个事务中根据业务需求可以把一些没有锁冲突的操作或者语句放在事务的前面先只是，可能会造成锁冲突的语句放在后面，减少锁冲突加大并发。

先说个非MySQL内部机制，但是可以通过语句实现的乐观锁。

## 乐观锁 
【解决问题】多线程并发场景对共享资源控制，避免数据冲突。例如售卖场景。
【具体技术】每次读数据的时候认为没有冲突不会上锁，只是在提交更新的时候去判断数据是否已经被其他事务修改。乐观锁的实现上一版使用判断版本号Version的方式：为数据增加一个版本标识，一版是通过为数据库表增加一个数字类型的version。当读取数据时候，将version字段一并读出，数据每更新一次，对此version值加1. 当提交更新的时候，判断数据库表当前版本号与第一次取出来的version值相等，则予以更新，否则认为是过期数据。
【适用场景】乐观锁假定事务之间的数据竞争概率是比较小的，只有提交的时候才校验，所以不会产生实际上的任何锁和死锁。乐观锁适用于读多写少-冲突较小的场景，加锁时间短，这样可以提高吞吐量。
【缺点】乐观锁不能解决脏读问题。并且增加读数据的次数，例如如果第二个用户恰好在第一个用户提交更改之前读取了该对象，那么当他完成了自己的更改进行提交时，数据库就会发现该对象已经变化了，这样，第二个用户不得不重新读取该对象并作出更改。这说明在乐观锁环境中，会增加并发用户读取对象的次数。

例子:电商下单减库存避免超卖。这个过程需要保证数据库一致性：某人点击秒杀后系统中查出来的库存量和实际扣减库存量一致
```mysql
CREATE TABLE `tb_product_stock` (
  `id` bigint(20) NOT NULL AUTO_INCREMENT COMMENT '自增ID',
  `product_id` bigint(32) NOT NULL COMMENT '商品ID',
  `number` INT(8) NOT NULL DEFAULT 0 COMMENT '库存数量',
  `create_time` DATETIME NOT NULL COMMENT '创建时间',
  `modify_time` DATETIME NOT NULL COMMENT '更新时间',
  PRIMARY KEY (`id`),
  UNIQUE KEY `index_pid` (`product_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='商品库存表';
```
不考虑并发：
```java
Public boolean updateStockRaw(Long productId) {
    ProductStock product = query(“select * from tb_product_stock where product_id = #{productId}”, productId);
    if (product.getNumber() > 0) {
         int updateCnt = update("UPDATE tb_product_stock SET number=number-1 WHERE product_id=#{productId}", productId); // 扣库存
         if(updateCnt > 0){    //更新库存成功
           return true;
        }
    }
    return false;
}
```
上述代码在多线程并发情况下会存在超卖可能。

乐观锁:
```java
    /**
     * 下单减库存
     * @param productId
     * @return
     */
    public boolean updateStock(Long productId){
        int updateCnt = 0;
        while (updateCnt == 0) {
            ProductStock product = query("SELECT * FROM tb_product_stock WHERE product_id=#{productId}", productId);
            if (product.getNumber() > 0) {
                updateCnt = update("UPDATE tb_product_stock SET number=number-1 WHERE product_id=#{productId} AND number=#{number}", productId, product.getNumber());
                if(updateCnt > 0){    //更新库存成功
                    return true;
                }
            } else {    //卖完啦
                return false;
            }
        }
        return false;
    }
```
使用乐观锁更新库存的时候不加锁，当提及更新时需要判断依据是否已经被修改（AND number = #{number}），只有在number 等于上一次查询到的number时才提交更新。

## 悲观锁
【解决问题】多线程并发场景对共享资源控制，避免数据冲突。例如售卖场景。
【具体技术】假定会发生冲突，屏蔽一切可能违反数据完整性的操作。因此每次读数据的时候都会上锁，直接block其他想要读数据的线程。Java synchronized就属于一种悲观锁，每次线程要修改稿数据时候都要先获得锁，保证同一时刻只有一个线程能操作数据，否则就会被block.
【适用场景】对并发控制严格的场景。
【缺点】加锁时间长，并发粒度小，可能会长时间限制其他用户的访问。
```
   /**
     * 更新库存(使用悲观锁)
     * @param productId
     * @return
     */
    public boolean updateStock(Long productId){
        //先锁定商品库存记录
        ProductStock product = query("SELECT * FROM tb_product_stock WHERE product_id=#{productId} FOR UPDATE", productId);
        if (product.getNumber() > 0) {
            int updateCnt = update("UPDATE tb_product_stock SET number=number-1 WHERE product_id=#{productId}", productId);
            if(updateCnt > 0){    //更新库存成功
                return true;
            }
        }
        return false;
    }
```

悲观锁在MySQL,Java有广泛的使用：
- MySQL的读锁，写锁，行锁等。
- Java的synchronized关键字

### 共享锁 / 读锁
共享锁(Shared Lock)又称读锁(Select Lock)，S锁， 是读取操作创建的锁。其他事务可以并发读取数据，但是任何事务都不能对数据进行修改（获取数据上的排他锁）。因为**加上共享锁后，对于update,insert,delete语句会自动加排它锁。**,因此如果事务T对数据A加上共享锁后，则其他事务只能对A再加共享锁，不能加排他锁。获得共享锁的事务只能读数据，不能修改数据。

加了共享锁后，**MySQL会对查询结果中的每行都加共享锁**，当没有其他线程对查询结果集中的任何一行使用排他锁时，可以成功申请共享锁，否则会被阻塞。其他线程也可以读取使用了共享锁的表，而且这些线程读取的是同一个版本的数据。
```mysql
select ... lock in share mode
```
【使用场景】
业务开发一般事务中并不用它。DBA会在主-从表的这种情况, 比如想在从表insert一条记录, 需要先将主表相关的数据加S锁锁定, 然后再insert从表, 来实现主从表数据一致性, 即有可能其他session会再此时delete主表的这条数据而造成只有从表有数据而主表无数据的数据不一致结果。
【例子】
<img src="lock-in-share-mode-select.png" width = "600" height = "300" alt="" align= />
然后在另一个查询窗口模拟另一个事务，对id=1的商品进行扣库存处理。会发现操作界面进入卡顿，然后超时报错。
<img src="lock-in-share-mode-update.png" width = "600" height = "300" alt="" align= />
【缺点】容易造成死锁。即session1在数据加S锁, 然后session2在相同数据也加S锁, 然后同时update, 必然会导致其中一个session的事务监测到deadlock,而终止事务。

### 排它锁
排它锁(Exclusive Lock)又称写锁(Update Lock)，X锁。若事务 1 对数据对象A加上X锁，事务 1 可以读A也可以修改A，其他事务不能再对A加任何锁，直到事物 1 释放A上的锁。这保证了其他事务在事物 1 释放A上的锁之前不能再读取和修改A。排它锁会阻塞所有的排它锁和共享锁。

读取为什么要加读锁呢：防止数据在被读取的时候被别的线程加上写锁,出现死锁。
```mysql
select ... for update
```

## 行锁与事务
设想一个情景，如果一个事务A要更新一行，如果刚好有另外一个事务B有这一行的行锁，那么事务A会被锁住，进入等待状态。问题是，既然进入了等待状态，那么等到这个事务自己获取到行锁要更新数据的时候，它读到的值是什么？

一句话重点：MySQL可重复读的隔离级别下，更新是当前读（具体说为更新数据都是先读后写，而这个读当前的值，称为“当前读” ），查询是一致性读。

另外，如果select语句不加锁，很可能出现也是典型的“丢失更新”问题：一个事务的更新操作会被另一个事务的更新操作覆盖。解决办法，在读取的时候设置一个读锁，保证当前读（读到最新数据的版本号）。例如：

加读锁（S锁，共享锁）：select k from t where id = 1 lock in share mode for update.  

加写锁（X锁，排他锁）：select k from t where id=1 for update. 

## 幻读与间隙锁(Gap Lock) 
幻读是指一个事务在前后两次查询同一个范围的时候，后一次查询看到了前一次查询没有看到的行的行。

事务在RR隔离级别下，普通的查询是一致性读，是不会看到事务插入的数据的。因此，幻读是在“当前读”下才出现--而这也是幻读出现的原因。

幻读专指“新插入的行”。幻读的危害：
1.破坏了业务的语义；
2.违反了数据的一致性。

为什么需要间隙锁？

当数据库的隔离级别是RR的情况下，由于MySQL的行锁在为数据上锁的时候需要数据在表中，也就是说对于新插入的数据MySQL是无法上锁的。这样就会出现幻读的情况。InnoDB为了解决幻读引入了间隙锁。

### 间隙锁
对于加锁的实体，可以是数据行。而数据行之间的空隙，也可以是加锁的实体。间隙锁有如下特性：
- 当一个涉及到为数据加锁的语句执行时候，会为涉及到的数据加行锁，同时为整个表的数据之间加间隙锁（gap lock）,这个行锁+间隙锁也叫next-key lock， InnoDB通过next-key lock解决了幻读的问题；
- 间隙锁开区间锁，next-key lock是个左开，右闭的空间；
- 间隙锁只会锁插入语句，其他的操作是不互斥的。与行锁的读写锁冲突不同，跟间隙锁存在冲突关系的，是“往这个间隙中插入一条记录”这个操作。间隙锁之间不存在冲突关系。

具体例子说明：
表t(id, c(有索引))有数据(3，3),(5，5),(7，7)。有如下3个事务： t1 ,t2锁不冲突， t3会被间隙锁block。next-key-lock会把表分为这几个区间：(-∞,3],(3,5],(5,7],(7,suprenum]，其中suprenum是一个不存在的最大值。
```sql
#t1
begin transaction;
select * from  t where c=5 for update;---会锁(3,5](5,7) 普通索引的等值查询从左往右直到第一个不满足条件的值（5，7）降为间隙锁,（3,5]是next-key lock

#t2
begin transaction;
update t set c=1 where c=5 for share mode;---S锁不冲突

#t3
begin transaction;
insert into t values(4,4);---因为间隙锁被block住
```
#### 间隙锁的缺点
间隙锁也并不是万能的，因为间隙锁导致同样的语句锁住更大的范围，其实影响了并发度，因此在某些情况下会造成死锁。比如下面的情况：

1. 判断断C=5是否存在；
2. 不存在就insert,存在就update；
3. 在并发的情况下，且c=5不存在，行锁无效，触发间隙锁，这时候事物2的insert需要等待事物1commit之后释放间隙锁。
4. 但是事物1，因为也insert导致了，不能释放锁就触发了死锁。
<img src="gap-lock.png" width = "600" height = "300" alt="" align= />
这种方式的解决方案，在满足业务的前提下，将事物的隔离级别改为RC，并且将binlog置为row。

## InnoDB加锁规则
以下所述InnoDB加锁规则适用于MySQL 5.x系列<= 5.7.24, 8.0系列<=8.0.13， 且隔离级别为可重复读隔离级别。且遵守两阶段锁协议，即所有加锁的资源，都是在事务提交或者回滚的时候才释放。
>原则1： 加锁的基本单位是next-key lock, next-key lock是前开后闭区间。
>原则2：查找过程中访问到的对象才会加锁。
>优化1：索引上的等值查询，给唯一索引加锁的时候，next-key lock退化为行锁。
>优化2：索引上的等值查询，向右遍历时且最后一个值不满足等值查询的时候，next-key lock退化为间隙锁。
>一个bug: 唯一索引上的范围查询会访问到不满足条件的第一个值为止。

另外，锁是加在索引上的。例如`select id from t where c=5 lock in share mode (c 有索引)`，因为只有访问到的对象才加锁，而这个查询使用到了覆盖索引，并不需要访问主键索引，所以主键索引上没有任何锁。因此`update t set d = d+1 where id=5`也可以执行。

另外，非唯一索引的范围锁没有优化规则，不会蜕变为行锁，因此锁的范围更大，例如`select * from t where c>=10 and c < 11 for update `,索引c上的next-key lock为 （5，10] 和 （10， 15]. 

另外，删除数据时候尽量加limit。这样不仅可以控制删除数据的条数，让操作更安全，还可以减小加锁的范围。

# 死锁
## 死锁和死锁检测
出现原因：循环的资源等待。举个例子：俩个事务，事务1:用户uid=1点赞,事务2：用户uid=1取消赞。如下：这时候在并发时候可能会造成死锁当事务1、事务2都执行完第一条语句时候，这时候事务1等待事务2执行完第二条语句释放，这时候事务2执行完第二条语句等待事务一释放
```sql
#事务1 点赞
BEGIN TRANSACTION;
UPDATE reply SET like_ammount=like_ammount+1 WHERE reply_id=1 ;
UPDATE user_sum SET like_sum=like_sum+1 WHERE uid=1;
COMMIT;
#事务2取消赞
BEGIN TRANSACTION;
UPDATE user_sum SET like_sum=like_sum-1 WHERE uid=1;
UPDATE reply SET like_ammount=like_ammount-1 WHERE reply_id=1 ;
COMMIT;
```
## 如何避免死锁
1. 按同一顺序访问对象。
2. 避免事务中的用户交互。
3. 保持事务简短并在一个批处理中。
4. 使用低隔离级别。
5. 使用绑定连接

## 死锁处理办法
- 等待锁超时，用innodb_lock_wait_timeout来设置；（默认50s）
用死锁检查的方式innodb_deadlock_detect设置为on，表示开启，一旦发生死锁回滚死锁链条中的某个事务让其他事务可以进行；

> 死锁检查真的很美好么？
死锁检查是一个O(n*n)的时间复杂度的操作，因为每一个被堵塞的线程都会检查是否是自己导致了死锁。导致会有大量的线程做无谓的死锁检查，最终现象是CPU很高，但是并发度很低。

# 参考
1. https://juejin.im/post/5b5ea32351882519f6477c5c#heading-6
2. 丁奇 https://time.geekbang.org/column/article/77083









