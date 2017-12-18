---
title: JVM调试工具入门
toc: false
banner: /images/jellyfish.jpg
author: NX
date: 2016-10-17 14:07:49
tags:
  - JVM
---

上周末连续两天凌晨都收到了系统的内存使用率过高报警，在分析监控系统记录的内存使用率曲线和内存使用情况后发现，主要是因为在老年代迟迟没有触发full gc导致监控系统连续多次监测到可用内存过低，而触发的报警。在系统触发一次full gc之后，内存使用率会显著下降，报警也没有持续下去。由于无法复现问题，具体原因仍未找到，但是通过此过程，学习到的内存分析工具与方法，却值得记录一番。

<!-- more -->

## jstat
> The jstat tool displays performance statistics for an instrumented HotSpot Java virtual machine (JVM).  

jstat是HotSpot Java虚拟机的性能统计工具。其基本的语法描述如下:

	 jstat [generalOption | outputOptions | vmid [interval[s|ms] [count]]]

### generalOption
generalOption是针对jstat功能的描述，包括两个参数 _-help_  与 _-options_ ，分别用于提示jstat的用法和支持的统计选项。该选项具有排他性，只能单独使用。

### outputOptions
outputOptions包括两类参数：_状态统计_ 和 _格式化输出_。状态统计参数用于指定jstat命令希望获取虚拟机哪方面的信息，而格式化参数则用于控制命令输出的展示样式。

jstat支持的状态统计参数（即jstat -options的输出）及功能描述如下:

	-class              统计类加载行为
	-complier           统计HotSpot即时编译器的行为
	-gc                 统计关于堆内存垃圾回收的行为
	-gccapacity         统计堆内存中各分区的使用情况
	-gccause            垃圾回收行为汇总，比-gcutil多输出最近两次垃圾回收的原因
	-gcnew,-gcold       新生代，老年代行为信息（内存量，阈值，垃圾回收次数等）
	-gcnewcapacity      新生代内存容量和使用量信息
	-gcoldcapacity      老年代内存容量和使用量信息
	-gcpermcapacity     持久区内存容量和使用量信息
	-gcutil             垃圾回收行为汇总
	-printcompilation   HotSpot编译方法统计

格式化参数包括三个：_-h n_ ，_-t_ 和 _-JjavaOption_. -h参数指定每隔n行重新显示一次列名;-t参数控制在输出第一列添加时间戳信息;-JjavaOption用于传递javaOption到java程序启动参数。比如，-J-Xms48m 设置java启动最小内存为48M。

### vmid
> Virtual machine identifier, a string indicating the target Java virtual machine (JVM).  

vmid是待监测的目标java程序标识符，可用 _jps_ 和Linux系统下的 _ps_ 等操作获取。vmid参数也支持以URI形式指定的远程主机上运行的java程序，不常用，不再赘述。

### interval and count
这两个参数用于控制jstat命令监测并输出的频率，interval默认参数为毫秒，如果设置了该参数，jstat命令将每隔interval的时间输出一次，count控制jstat命令输出样例的个数，也就是输出的行数。如果不设置，默认为无限，jstat会一直进行输出直到目标程序退出或者jstat命令终止。

### 样例
使用 _-gcutil_ 参数查看进程16058发生的垃圾回收行为，每2秒打印一次结果，一共打印5次。命令输出的每一列都使用简称的形式展示，下图中 _S0_ 表示Survivor 0区的空间使用比例， _E_, _O_, _P_ 分别代表Eden, Old和Perm空间使用率，_YGC_ 表示young gc的次数，_YGCT_ 表示young gc消耗的时间。_GCT_ 则用来统计执行gc的总时间。

<div align = center>

![](jvm-debug/jstat%20gcutil.jpg)

</div>

使用 _-gc_ 参数查看更详细的垃圾回收与堆内存信息。 _S0_ 以及 _E_ 等各内存区域标识后缀中 _**C**_ 表示 Capacity, _**U**_ 表示Utilization，参数对应的数值显示的是真实容量，而不是百分比。

<div align = center>

![](jvm-debug/jstat%20gc.jpg)

</div>

使用 _-gcnew_ 参数查看新生代的内存和垃圾回收情况，由于命令附带了参数 _t_ ，所以第一列打印了时间戳的信息。 _TT_ 参数表示对象在gc时被放入老年代的年龄期限阈值，_MTT_ 参数表示最大阈值. 这两个参数之间 _MTT_ 设定了 _TT_ 可取的最大值，_TT_ 实际控制着对象进入老年代的年龄限制，会随着垃圾回收过程而发生变化。

> 当年龄从1开始的对象大小累计超过了Survivor区域的1/2(TargetSurvivorRatio所定义)时，会计算一个Thenuring Threshold，超过这个年龄的新生代对象会进入到老年代，即使这时候新生代还有很多的空间。注意MaxTenuringThreshold只是设置了最大的Thenuring Threshold，不是说只有大于Max Tenuring Threshold才会进入到老年代，而是只要超过了计算出来的Tenuring Threshold就会进入老年代，MaxTenuringThreshold规定了Tenuring Threshold的最大值而已。Tenuring Threshold这个值在每一轮GC后都会动态计算，它与TargetSurvivorRatio以及Survivor区的大小有关系，TargetSurivivor默认是50即Survivor的1/2, 会计算出一个Desired Survivor Size，当年龄从1开始的对象大小累计超过了这个Desired Survivor Size，那么这个age就是Tenuring Threshold的值

<div align = center>

![](jvm-debug/jstat%20gcnew.jpg)

</div>

使用 _-gcnewcapacity_ 参数查看新生代的内存占用情况。_NGC_ : new generation capacity, 新生代内存大小。_NGCMN_ 表示新生代分配内存的最小值，_NGCMX_ 新生代分配内存的最大值，`NGCMX=S0CMX+S1CMX+ECMX`.

<div align = center>

![](jvm-debug/jstat%20gcnewcapacity.jpg)

</div>


## jstack

jstack用于打印指定java进程或者核心文件中所有java线程当前时刻正在执行的方法堆栈追踪情况，也就是线程的snapshot。生成线程的快照主要用于定位线程长时间出现停顿的原因：如死锁，等待外部资源等。jstack的命令格式如下：

	jstack [option] pid/executable core/[server-id@]remote-hostname-or-IP

- pid
待追踪的java进程ID，可使用jps等方式获得
- executable
产生core dump的java可执行程序(jar文件)
- core
打印栈追踪信息的核心文件

### options
	-F      当正常输出的请求(jstack [-l] pid)不被响应时，强制执行stack dump
	-l      除了堆栈外，打印关于锁的附加信息
	-m      如果调用本地方法，同时打印java和本地C/C++栈帧
	-h      打印帮助

jstack在分析死锁，阻塞等性能问题上非常有用，根据打印的堆栈信息可以定位到出问题的代码段。定位问题的思路根据要解决的问题而发生不同，比如可以首先找到java进程中最耗cpu的线程，再根据线程id在jstack的输出中定位，或者使用指定的线程名称定位。下面看一下jstack的输出格式：

<div align = center>

![](jvm-debug/jstack.jpg)

</div>

	main 线程名称
	prio=5 线程优先级为5
	tid=7f8a7c001800 jvm中线程标识符
	nid=0x700000a19000 16进制表示的本地线程标识符
	runnnable 线程状态
	[70000a17000] 线程的起始地址
	从第二行起为函数调用栈

上述信息中最重要的状态莫过于线程的状态，当程序发生问题时往往能够据此帮我们找到问题的所在。在jstack的输出中，线程所处的状态包括：

- Runnable: 正在运行  
- Wait on condition: 该状态出现在线程等待某个条件的发生。具体是什么原因，可以结合 stacktrace来分析。最常见的情况是线程在等待网络的读写。如果网络数据没准备好，线程就等待在那里。另外一种出现 Wait on condition的常见情况是该线程在 sleep，等待 sleep的时间到了时候，将被唤醒。
- Wait for monitor entry: Java通过对象监视器来进行线程的互斥与同步的，每个对象都有一个对象监视器，在对对象加锁的过程中，任何时刻只有一个线程拥有这个对象监视器，其他请求获得此资源的线程将会被分为两种：在线程获取到对象监视器，但等待的资源仍未到达时，线程可能调用Object.wait()，释放锁并进入Object.wait()的状态，重新等待；而那些从未获得过此对象监视器的线程就将被标识为Wait for monitor entry的状态。
- Object.wait: 等待对象监视器（锁）的状态。
关于两种等待状态可以参考下面的图（来源于网络）：  

<div align = center>

![](jvm-debug/waitstate.jpg)

</div>

## jmap

jmap用于生成java进程的heapdump或者堆内存的详细信息。可以用来分析java程序堆内存被各种实例占据的比例或者GC回收了哪些对象等信息。jmap的命令格式与jstack一致，不再赘述。

### options
	<no option>                            打印每一个共享对象的起始地址，范围等信息
	-dump:\[live,]format=b,file=<filename>   以二进制形式打印java堆的dump信息到指定文件中，指定live参数，只打印存活的对象
	-heap                                  显示java堆的详细信息：GC算法，堆配置以及分代情况
	-histo\[:live]                         显示堆中每一个java类实例的个数，占据空间的大小，类名全称等。live参数控制输出存活对象。
	-premstat                              以classLoader为统计入口，显示永久代的生存状态。每个加载器的名称，存活状态，地址，父加载器和已经加载类的数量等信息将被打印。
	-F                                     在正常的命令对-dump或者-histo没有响应时，强制执行，生成dump信息
	-J<flag>                                map启动时传递给jvm的参数，比如在64位机器上就要使用jmap -J-d64 -heap pid来执行命令。

---

### 参考链接
1.[http://docs.oracle.com/javase/7/docs/technotes/tools/share/jstat.html](http://docs.oracle.com/javase/7/docs/technotes/tools/share/jstat.html)
2.[http://docs.oracle.com/javase/7/docs/technotes/tools/share/jstack.html](http://docs.oracle.com/javase/7/docs/technotes/tools/share/jstack.html)
3.[http://docs.oracle.com/javase/7/docs/technotes/tools/share/jmap.html](http://docs.oracle.com/javase/7/docs/technotes/tools/share/jmap.html)  
4.[https://my.oschina.net/feichexia/blog/196575](https://my.oschina.net/feichexia/blog/196575)  
5.[http://go-on.iteye.com/blog/1673894](http://go-on.iteye.com/blog/1673894)  
6.[http://blog.csdn.net/iter_zc/article/details/41802365](http://blog.csdn.net/iter_zc/article/details/41802365)  
7.《深入理解JVM虚拟机》周志明著
