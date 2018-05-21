---
title: MyBatis generator自动生成代码详细配置
toc: false
banner: /images/pun.jpeg
date: 2017-11-01 22:47:09
tags:
  - 数据库
  - MySQL
author: GSM
---

# MyBatis

MyBatis Generator (下文简称MGB)是Mybatis官方推出的MyBatis和iBatis代码生成器。引入MGB jar包后，MGB会根据指定的配置文件读取数据库表生成一个访问数据库的接口，实现对数据库进行基本的CRUD甚至是一些联表操作。

<!-- more -->

使用MGB会生成：

- Java POJO类
- MyBatis/iBatis SQL Map XML 文件(具体sql代码)。
- mapper 文件(相当于DAO，定义操作数据库的java接口)

![mgb](1.jpg.png)
## 1. 使用mybatis-generator实现CRUD
### 1.1. 下载MGB JAR
[MBG下载地址](http://repo1.maven.org/maven2/org/mybatis/generator/mybatis-generator-core/)
### 1.2. 配置mybatis-generator-config.xml
如果要想实现MGB代码生成器，需要先配置一个基础的XML配置文件(本文定义为mybatis-generator-config.xml)。该配置文件主要告诉MBG三件事：

1.如何连接到数据库

2.生成什么POJO对象(根据哪张表生成对象，对象存放在哪个文件路径下)

3.mapper文件生成哪些操作数据库的方法

mybatis-generator-config.xml 的文件结构为：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE generatorConfiguration
        PUBLIC "-//mybatis.org//DTD MyBatis Generator Configuration 1.0//EN"
        "http://mybatis.org/dtd/mybatis-generator-config_1_0.dtd">

<generatorConfiguration>
    <!-- 具体配置内容 -->
    <properties>
    </properties>

    <classPathEntry> 指定mgb jar包位置
    </classPathEntry>

    <context>
        <property> (0个或多个)
        <plugin> (0个或多个) 使用哪些插件
        <commentGenerator> (0个或1个) 生成的代码要不要注释
        <jdbcConnection> (1个) 配置连接的jdbc
        <javaTypeResolver> (0个或1个) 配置java数据类型和sql数据类型映射
        <javaModelGenerator> (1个) 生成PO类的位置
        <sqlMapGenerator> (0个或1个) mapper映射文件生成的位置
        <javaClientGenerator> (0个或1个) mapper接口生成的位置
        <table> (1个或多个) 根据哪个mysql table生成
    </context>

</generatorConfiguration>      
```
[详细配置及对应含义可以参考](http://blog.csdn.net/isea533/article/details/42102297). 这里重点说下生产环境常用的配置。

### context元素
context元素用于指定生成POJO对象的环境，例如指定连接的数据库，要生成对象的类型和路径。

#### context属性`defaultModelType`
定义了MBG如何生成**实体类**。一般选择`flat模型`,该模型为每一张表只生成一个实体类。这个实体类包含表中的所有字段。**这种模型最简单，推荐使用。**

一般情况下，我们使用如下的配置即可：
```xml
<context id="Mysql" defaultModelType="flat">
```

#### `<plugin>`元素使用插件。
插件用于扩展或修改通过MyBatis Generator (MBG)代码生成器生成的代码。生产环境常见的插件：

- `<plugin type="org.mybatis.generator.plugins.RenameExampleClassPlugin"/>`
    + 该插件用于重命名生成的XXXExample类，通过配置 searchString和replaceString属性来完成。具体通过配置`searchString`和`replaceString`属性使用正则表达式实现。
- `<plugin type="org.mybatis.generator.plugins.EqualsHashCodePlugin"/>`
    + 这个插件用来给生成的Java POJO类生成equals和hashcode方法
- `<plugin type="org.mybatis.generator.plugins.SerializablePlugin"/>`
    + 这个插件用来给生成的Java POJO类生成的Java模型类添加序列化接口，并生成serialVersionUID字段

更多插件可以参见mybatis官方插件库[mybatis官方插件库](http://www.mybatis.org/generator/reference/plugins.html)和[第三方插件库](https://github.com/itfsw/mybatis-generator-plugin).


一份完整的mybatis-generator-config 示例：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE generatorConfiguration
        PUBLIC "-//mybatis.org//DTD MyBatis Generator Configuration 1.0//EN"
        "http://mybatis.org/dtd/mybatis-generator-config_1_0.dtd">
<generatorConfiguration>
    <!-- step 1: classPathEntry:数据库的JDBC驱动,换成你自己的驱动路径 -->
    <classPathEntry
            location="D:\Program Files\apache-maven-3.0.3-bin\maven-repository\mysql\mysql-connector-java\5.1.20\mysql-connector-java-5.1.20.jar"/>

    <context id="MBG" targetRuntime="MyBatis3" defaultModelType="flat">  
        <!-- defaultModelType指定生成pojo的模型 -->

        <!-- 使用插件 -->
        <!--<plugin type="plugin.SelectByPagePlugin" /> -->
        <plugin type="org.mybatis.generator.plugins.RenameExampleClassPlugin">
          <!-- 此处是将Example改名为Criteria -->
            <property name="searchString" value="Example$"/>
            <property name="replaceString" value="Criteria"/>
        </plugin>
        <plugin type="org.mybatis.generator.plugins.EqualsHashCodePlugin"/>
        <plugin type="org.mybatis.generator.plugins.SerializablePlugin"/>

        <commentGenerator>
            <!-- 去除自动生成的注释 -->
            <property name="suppressAllComments" value="true"/>
            <property name="suppressDate" value="true"/>
        </commentGenerator>

        <!--数据库连接的信息：驱动类、连接地址、用户名、密码 -->
        <jdbcConnection driverClass="com.mysql.jdbc.Driver"
                        connectionURL="jdbc:mysql:loadbalance://xxx.xxx.xxx.xxx:3306/database_name?useUnicode=true&amp;characterEncoding=UTF8"
                        userId="username" password="password">
        </jdbcConnection>

        <!-- 默认false，把JDBC DECIMAL 和 NUMERIC 类型解析为 Integer，为 true时把JDBC DECIMAL 和
      NUMERIC 类型解析为java.math.BigDecimal -->
        <javaTypeResolver>
            <property name="forceBigDecimals" value="false"/>
        </javaTypeResolver>

        <!--  targetProject:生成PO类的位置 -->
        <javaModelGenerator targetPackage="com.jd.myproject.domain.actPC"
                            targetProject="D:\GitPro\myproject\myproject-domain\src\main\java">
            <!-- enableSubPackages:是否让schema作为包的后缀 -->
            <property name="enableSubPackages" value="true"/>
            <!-- 从数据库返回的值被清理前后的空格 -->
            <property name="trimStrings" value="true"/>
        </javaModelGenerator>

        <!-- targetProject:mapper映射文件生成的位置
           如果maven工程只是单独的一个工程，targetProject="src/main/java"
           若果maven工程是分模块的工程，targetProject="所属模块的名称"，例如：
           targetProject="ecps-manager-mapper"，下同-->
        <sqlMapGenerator targetPackage="actPC"
                         targetProject="
                         D:\GitPro\myproject\myproject-dao\src\main\resources\sqlmap">
            <!-- enableSubPackages:是否让schema作为包的后缀 -->
            <property name="enableSubPackages" value="true"/>
        </sqlMapGenerator>

        <!-- targetPackage：mapper接口生成的位置 -->
        <javaClientGenerator type="XMLMAPPER"
                             targetPackage="com.jd.myproject.dao.actPC.mapper"
                             targetProject="D:\GitPro\myproject\myproject-dao\src\main\java">
            <!-- enableSubPackages:是否让schema作为包的后缀 -->
            <property name="enableSubPackages" value="true"/>
        </javaClientGenerator>
        <!-- tableName:用于自动生成代码的数据库表；domainObjectName:对应于数据库表的javaBean类名 -->

        <!-- 指定数据表 -->
        <table tableName="student_audit" domainObjectName="StudentAudit"
               enableCountByExample="true" enableUpdateByExample="true"
               enableDeleteByExample="false" enableSelectByExample="true"
               selectByExampleQueryId="true" enableInsert="true">
        </table>
    </context>
</generatorConfiguration>
```

添加到如下路径

![directory](generatorDir.png)

### 1.3. 生成mybatis-generator-maven-plugin
在domain的pom文件中添加mybatis-generator的maven plugin插件。

```pom
<dependencies>
    ...
       <build>
        <plugins>
            <plugin>
                <groupId>org.mybatis.generator</groupId>
                <artifactId>mybatis-generator-maven-plugin</artifactId>
                <version>1.3.5</version>
                <configuration>
                    <!--配置文件的位置-->
                    <configurationFile>src/main/resources/mybatis-generator-config.xml
                    </configurationFile>
                    <verbose>true</verbose>
                    <overwrite>true</overwrite>
                </configuration>
            </plugin>
        </plugins>
    </build>
```

使用idea的maven插件直接快速生成, 对domain进行 `mvn clean`,`mvn package`。会发现maven 生成了一个 MGB的一个插件
![plugins](mbgplugin.png)

## 1.4. MGB生成代码

直接点击mybatis-generator:generate就可生成。

## 2. 使用mybatis-generator实现高级操作
```xml
        <!-- 指定数据表 -->
        <table tableName="test_table" domainObjectName="TestPojo"
               enableCountByExample="true" enableUpdateByExample="true"
               enableDeleteByExample="false" enableSelectByExample="true"
               selectByExampleQueryId="true" enableInsert="true">
        </table>
```

在`mybatis-generator-config.xml`中我们定义了一系列`ByExample`形式的操作数据库的java接口。如果把`enableCountByExample` 等等这些`ByExample`接口都置为false，那么MGB只会生成基本的CRUD增删改查的接口，难以满足生产环境mysql的复杂语句，例如根据条件搜索，统计数量，甚至是一些联表操作。

当把`enableCountByExample` 等等这些`ByExample`接口都置为true后，会生成一个`xxxExample`类，该类可以理解为一个动态配置where条件的对象。`xxxExample`类包括一个静态内部类`Creteria`，`Creteria`包含一个Criteria条件集合，集合内的条件是由`And`逻辑与连接的。当使用`or`方法会创建一个Criteria属性，Criteria和Criteria对象之间是逻辑或。

另外：Example类的distinct字段用于指定DISTINCT查询。orderByClause字段用于指定ORDER BY条件,这个条件没有构造方法,直接通过传递字符串值指定。

```java
public class StudentExample {
    protected String orderByClause;

    protected boolean distinct;

    protected List<Criteria> oredCriteria;

     public void or(Criteria criteria) {
        oredCriteria.add(criteria);
    }

    public Criteria or() {
        Criteria criteria = createCriteriaInternal();
        oredCriteria.add(criteria);
        return criteria;
    }
    ...
}
```

另外，如果仍然有一些情况mgb自动生成的代码仍然满足不了我们的需求，如进行联表。我们可以扩展example类。

例如实现联表操作。在xxxExample类增加方法
```java
        public Criteria multiColumnOrClause(String value) {
            addCriterion("(b.name like " +"\"%" +value +"%\"" + " OR id = " + Integer.valueOf(value)+")");
            return (Criteria)this;
        }
```
在mapper中增加联表语句即可。

## 3. 使用mybatis打印sql操作日志
MyBatis内置有日志工厂，可以使用Log4j对每一条数据库操作进行日志打印。这对开发环境快速定位问题非常重要。通过配置`log4j.properties`可以实现：

- 日志记录每一条数据库操作语句
- 日志记录每一条数据库操作的输入
- 日志记录每一条数据库操作的结果

```java
log4j.rootLogger=DEBUG,FileLog
log4j.logger.java.sql = DEBUG
log4j.logger.java.sql.Connection = DEBUG
log4j.logger.java.sql.Statement = DEBUG
log4j.logger.java.sql.PreparedStatement = DEBUG
log4j.logger.java.sql.ResultSet = DEBUG
log4j.logger.com.ibatis = DEBUG
log4j.logger.com.ibatis.common.jdbc.SimpleDataSource = DEBUG
log4j.logger.com.ibatis.common.jdbc.ScriptRunner = DEBUG
log4j.logger.com.ibatis.sqlmap.engine.impl.SqlMapClientDelegate = DEBUG

# Console config 屏幕打印
#log4j.appender.stdout=org.apache.log4j.ConsoleAppender
#log4j.appender.stdout.Target=System.out
#log4j.appender.stdout.layout=org.apache.log4j.PatternLayout
#log4j.appender.stdout.layout.ConversionPattern=%d{yyyy-MM-dd HH:mm:ss} [%7r] [%5p] - %30.30c - %m \n

#File Log config 文件输出
log4j.appender.FileLog=org.apache.log4j.DailyRollingFileAppender
log4j.appender.FileLog.File=D:/export/ejshop/jshope.log
log4j.appender.FileLog.layout=org.apache.log4j.PatternLayout
log4j.appender.FileLog.layout.ConversionPattern=%d{yyyy-MM-dd HH:mm:ss} [%7r] [%5p] - %30.30c - %m \n
log4j.appender.FileLog.encoding=UTF-8
```

# 参考
1. [MBG官网](http://www.mybatis.org/generator/generatedobjects/exampleClassUsage.html)
