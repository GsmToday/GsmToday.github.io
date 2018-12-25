---
title: 从数据库连接池想到的
toc: true
banner: /images/xmas.jpeg
date: 2018-12-25 22:48:02
author: GSM
tags:
---
[TOC]
# 长连接 VS 短连接 
先澄清个概念，我们通常说的长连接和短连接其实是**TCP连接**。因为HTTP是请求/响应模式，只要服务端给了响应，本次HTTP连接就结束了。而TCP连接是一个双向的通道，它是可以保持一段时间不关闭的，因此TCP连接才有真正的长连接和短连接一说。

所以“HTTP连接”这个词就不应该出现，更准确的是HTTP请求和HTTP响应，而HTTP请求和HTTP响应都是通过TCP连接这个通道来回传输的[1](https://www.jianshu.com/p/3fc3646fad80)。

那什么是长连接和短连接呢？
- 短连接是指通信双方接收完数据后立刻断开连接；
- 长连接是指通信双方接收完数据后不断开连接，而是保持一段时间连接，可以继续传输数据。

## 为什么要有长连接？
建立连接代价太大，长连接意味着连接会被复用。长连接可以使多个HTTP连接复用同一个TCP连接，这就节省了很多TCP连接建立和断开消耗。

比如你请求了博客园的一个网页，这个网页里肯定还包含了CSS、JS等等一系列资源，如果你是短连接（也就是每次都要重新建立TCP连接）的话，那你每打开一个网页，基本要建立几个甚至几十个TCP连接，这得浪费了多少资源…

但如果是长连接的话，那么这么多次HTTP请求（这些请求包括请求网页内容，CSS文件，JS文件，图片等等），其实使用的都是一个TCP连接，很显然是可以节省很多消耗的。[1](https://www.jianshu.com/p/3fc3646fad80)。

另外，长连接并不是永久连接的。如果一段时间内（具体的时间长短，是可以在header当中设置的，即设置超时时间）这个连接没有HTTP请求发出的话，那么这个连接就会被断掉。

## 怎么设置长连接？
WEB类请求：客户端HTTP请求header设置支持Connection=keep-alive支持长连接。服务端Nginx设置支持：
```nginx
http{
keepalive_timeout  60
}
```
TCP类请求：可以使用Netty建立长连接。

# 连接池
对于共享资源，有一个很著名的设计模式：**资源池**。该模式正是为了解决资源频繁分配、释放所造成的问题的。把该模式应用到数据库连接管理领域，就是建立一个数据库连接池；（类似还有线程池以及Redis连接池），提供一套高效的连接分配，使用策略，最终目标是实现连接的高效、安全的复用[2](https://blog.csdn.net/shuaihj/article/details/14223015)。

### 数据库连接池
数据库连接池的基本原理是在内部对象池中维护一定数量的数据库连接，并对外暴露数据库连接获取和返回方法（注意是返回不是关闭）。外部使用者可以通过getConnection方法获取连接，使用完毕后再通过realeaseConnection方法将连接返回，注意此时连接并没有关闭，二手由连接池管理器回收，并为下一次使用做好准备。

数据库连接池技术带来的优势：
1.资源重用 - 避免频繁创建、释放连接引起的大量性能开销。
2.更快的系统响应速度。
3.统一的连接管理，避免无尽的连接导致数据库连接泄露。
4.更为重要是我们可以通过连接池的管理机制监视数据库的连接数量，使用情况。

在较为完备的数据库连接实现中，可根据预先的连接占用超时设定，强制回收被占用连接。从而避免常规数据库连接中可能出现的资源泄露。

### 实践
- Question: Java项目中是怎么使用数据库连接池的？怎么取，怎么返回？
- Answer: 

1. 如果不用连接池，最原始的版本是手动建立连接，手动释放（生产环境不这么用）
```java
   public static void simple() throws SQLException, ClassNotFoundException {
        Class.forName("com.mysql.jdbc.Driver");
        System.out.println("成功加载驱动");

        PreparedStatement psmt = null;
        Connection connection = null;
        ResultSet resultSet = null;

        RedisProperties.Jedis jedis=new RedisProperties.Jedis();
        jedis.getPool();

        try {
            String url = "jdbc:mysql://xx.xx.xx.xx:3306/xxxx?characterEncoding=UTF-8&useSSL=false";

            connection = DriverManager.getConnection(url, "root", "123456");
            System.out.println("成功获取连接");

            psmt = connection.prepareStatement("select 1");
            resultSet = psmt.executeQuery();
            while (resultSet.next()) {
                System.out.println(resultSet.getString(1));
            }
            System.out.println("成功操作数据库");


        } catch (Throwable t) {
            // TODO 处理异常
            t.printStackTrace();
        } finally {
            if (resultSet != null) {
                resultSet.close();
            }
            if (psmt != null) connection.close();{
                psmt.close();
            }
            if (connection != null) {
                connection.close();
            }
            System.out.println("成功关闭资源");
        }

    }
```
这样的缺点很显然, 每次都要客户端手动建立连接到数据库，再手动释放连接。如果忘记释放，将会连接越来越多，造成内存泄露。而且每次建立连接代价很大(时间长)，每次db操作的性能都很差。

生产环境用法：
使用数据库连接池（例如下例Druid）, 连接池指定以下参数管理数据库连接：
- timeBetweenEvictionRunsMillis： 间隔多久才进行一次检测，检测需要关闭的空闲连接，单位是毫秒。数据库连接池建立的连接都是长连接，但是在连接池在做管理的时候，会回收不活跃的连接。

- initialSize：初始化时建立物理连接的个数。连接池初始化大小。

- maxActive 最大连接池数量
- minIdle 最小连接池数量

而每次获取连接和返回连接，是由MyBatis去实现。。

更多参数可以参考Druid参数官方文档[3](https://github.com/alibaba/druid/wiki/DruidDataSource%E9%85%8D%E7%BD%AE%E5%B1%9E%E6%80%A7%E5%88%97%E8%A1%A8
)


```xml
 <bean id="dataSource" class="com.alibaba.druid.pool.DruidDataSource" init-method="init" destroy-method="close">
        <!-- 基本属性 url、user、password -->
        <property name="url" value="${jdbc.url}"/>
        <property name="username" value="${jdbc.user}"/>
        <property name="password" value="${jdbc.password}"/>
        <!-- 配置初始化大小、最小、最大 -->
        <property name="initialSize" value="30"/>
        <property name="minIdle" value="1"/>
        <property name="maxActive" value="500"/>
        <!-- 配置获取连接等待超时的时间 -->
        <property name="maxWait" value="6000"/>

        <!-- 配置间隔多久才进行一次检测，检测需要关闭的空闲连接，单位是毫秒 -->
        <property name="timeBetweenEvictionRunsMillis" value="6000"/>

        <!-- 配置一个连接在池中最小生存的时间，单位是毫秒 -->
        <property name="minEvictableIdleTimeMillis" value="30000"/>

        <property name="validationQuery" value="SELECT 'x'"/>
        <property name="testWhileIdle" value="true"/>
        <property name="testOnBorrow" value="false"/>
        <property name="testOnReturn" value="false"/>

        <!-- 打开PSCache，并且指定每个连接上PSCache的大小 -->
        <property name="poolPreparedStatements" value="true"/>
        <property name="maxPoolPreparedStatementPerConnectionSize" value="20"/>
    </bean>
    <bean id="sqlSessionFactory" class="com.baomidou.mybatisplus.spring.MybatisSqlSessionFactoryBean">
        <property name="dataSource" ref="dataSource"/>
        <!-- 自动扫描Mapping.xml文件 -->
        <property name="mapperLocations" value="classpath:mybatis/mapper/*.xml"/>
        <property name="configLocation" value="classpath:mybatis/mybatis-config.xml"/>
        <property name="typeAliasesPackage" value="com.xiaojukeji.sec.data.*"/>
        <property name="plugins">
            <array>
                <!-- 分页插件配置 -->
                <bean id="paginationInterceptor" class="com.baomidou.mybatisplus.plugins.PaginationInterceptor">
                    <property name="dialectType" value="mysql"/>
                </bean>
            </array>
        </property>
        <!-- 全局配置注入 -->
        <property name="globalConfig" ref="globalConfiguration"/>
    </bean>

    <bean id="txManager" class="org.springframework.jdbc.datasource.DataSourceTransactionManager">
        <property name="dataSource" ref="dataSource"/>
    </bean>
    <tx:annotation-driven transaction-manager="txManager"/>
```

# 参考

[各种数据库连接池对比](https://github.com/alibaba/druid/wiki/%E5%90%84%E7%A7%8D%E6%95%B0%E6%8D%AE%E5%BA%93%E8%BF%9E%E6%8E%A5%E6%B1%A0%E5%AF%B9%E6%AF%94) 

[数据库连接泄露的问题](https://blog.csdn.net/u012089657/article/details/48897151
https://github.com/alibaba/druid/wiki/%E5%B8%B8%E8%A7%81%E9%97%AE%E9%A2%98) 