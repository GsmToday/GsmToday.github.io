---
title: 庖丁解牛-多服务器并发场景下乐观锁的实际应用
date: 2017-07-23 21:30:09
toc: false
thumbnail: /images/niu.jpg
author: GSM
tags:
	- Java
	- 并发编程
categories: 学习积累
---

庖丁解牛-多服务器并发场景下乐观锁的实际应用

笔者面临的一个业务场景为：项目中多条业务线的实现都需要创建一个实例ID(instanceID)，实例ID的值为系统当前的实例ID最大值+1。这样就会面临着在同一时间下有多个用户更新实例ID，造成并发冲突的问题。

笔者首先想到的解决方法是使用关键字`synchronized`来解决。但是组内同事提出光有`synchronized`是不够的，因为`synchronized`只能解决单台机器的JVM多线程并发问题，无法解决线上多台服务器分布式导致的并发问题。

<!-- more -->

同事进一步提出方案，可以尝试使用乐观锁解决,**使用一个Sequence表记录系统中实例ID的最大值(INSTANCE_SEQUENCE_ID)**.当前机器创建实例ID时:

1. 先读取数据库中`INSTANCE_SEQUENCE_ID`为`sequenceId`；
2. 接着进行业务处理
3. 最后更新Sequence表的`INSTANCE_SEQUENCE_ID`值为新创建的实例ID值，即+1。

Step3 更新操作实际为`compare and set`乐观锁控制：
```
<update  id="updateSequence" parameterType="Sequence">
  UPDATE <include refid="tableName"/> SET value=#{maxId} WHERE value= #{sequenceId} and sequence_key =#{sequenceKey}
</update>
```

比较数据库中`INSTANCE_SEQUENCE_ID`字段数值是否与此次操作获取的`sequenceId`一致，如一致则表明未有其他机器进行操作，不会丢失更新，可以进行更新。如果不一致，说明其他机器创建了实例ID，则不允许本台机器进行更新。需要重试，再进行一遍`1-2-3`操作.

这种方案已经可以解决单台机器多线程并发冲突和多服务并发冲突了，但是存在性能缺陷：每次创建一个页面实例ID，都需要查询/更新数据库多次，这样效率大打折扣，在线上生产环境可能不允许这种方案的实现。于是我们继续阅读项目老代码，寻求解决之策。果然老代码使用了一个方案提高了性能。

一言以蔽之，该方案赋予每台机器一个范围scope = 100, 每台机器在范围内进行`sequeceId`自增，不用查询/更新数据库。
当超出范围，即自增加后的`sequeceId`为101时，再进行step1-2-3.

`sequence java bean:`
```java
public class Sequence {
    /**
     * sequenceId变动范围
     */
    private int scope = 100;
    /**
     * 当前sequenceID
     */
    private Long currentSequenceId = null;

    /**
     * 开始的sequenceID
     */
    private  Long startSequenceId = null;

    private Long endSequenceId = null;

    public DbSequence(){
    }

    public DbSequence(int scope){
        this.scope = scope;
    }
    /**
     * @param startId
     */
    public  synchronized void setSequenceId(Long startId){
        currentSequenceId = startId;
        startSequenceId = startId;
        endSequenceId = startSequence
    }
}    
```
算法流程如图:  
![procedure](procedure.png)

## 总结
同一台机器的并发冲突可以使用synchronize。
乐观锁解决多台机器并发冲突，用scope 100降低冲突概率
