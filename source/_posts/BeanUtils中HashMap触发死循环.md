---
title: BeanUtils中HashMap触发死循环
toc: true
thumbnail: /images/WechatIMG472.jpeg
date: 2019-09-03 17:30:22
author: GSM
tags: Java
categories: 业务实践
---
一次HashMap多线程不安全的踩坑...
<!--more-->
# 故障现场
2019-09-03 下午16点48收到CPU Idle小于20%的报警。
<img src="monitor.png" width = "800" height = "600" align=center />

这个时候立刻查看了接口成功率，调用量，延时等指标，发现均为正常：
<img src="monitor2.png" width = "800" height = "600" align=center />

再看硬件指标：
<img src="monitor3.png" width = "800" height = "600" align=center />
发现只有这台（docker4）从16点37开始CPU idle不断下降，一个小时之内跌到0. 另外查看docker物理机监控，发现物理机CPU 情况正常，排除物理机问题。

与此同时（报警时刻，CPU idle 20%），查看了JVM jstack :

发现：
<img src="jstack.png" width = "800" height = "600" align=center />
```java
"http-nio-8099-exec-72" #117 daemon prio=5 os_prio=0 tid=0x00007f6398041800 nid=0xdf7 runnable [0x00007f6358cc8000]
   java.lang.Thread.State: RUNNABLE
    at java.util.WeakHashMap.get(WeakHashMap.java:403)
    at ma.glasnost.orika.metadata.TypeKey.getTypeIndex(TypeKey.java:55)
    at ma.glasnost.orika.metadata.TypeKey.valueOf(TypeKey.java:47)
    at ma.glasnost.orika.metadata.TypeFactory.intern(TypeFactory.java:421)
    at ma.glasnost.orika.metadata.TypeFactory.valueOf(TypeFactory.java:69)
    at ma.glasnost.orika.impl.MapperFacadeImpl.typeOf(MapperFacadeImpl.java:1045)
    at ma.glasnost.orika.impl.MapperFacadeImpl.resolveMappingStrategy(MapperFacadeImpl.java:154)
    at ma.glasnost.orika.impl.MapperFacadeImpl.map(MapperFacadeImpl.java:675)
    at ma.glasnost.orika.impl.MapperFacadeImpl.map(MapperFacadeImpl.java:655)
    at com.xiaojukeji.sec.upm.common.utils.BeanUtils.mapList(BeanUtils.java:108)
    at com.xiaojukeji.sec.upm.core.api.controller.coreapi.UserController.userAreaList(UserController.java:155)
    at com.xiaojukeji.sec.upm.core.api.controller.coreapi.UserController$$FastClassBySpringCGLIB$$bc29b0e0.invoke(<generated>)
    at org.springframework.cglib.proxy.MethodProxy.invoke(MethodProxy.java:204)
```
多次top, 占用CPU的线程ID没有变过；jstack多次发现代码一直在WeakHashMap的get的函数上.

这个时候查看报警时间（16点48）的业务日志，发现无论是访问日志还是error日志，都是正常的。在事后补看最开始CPU Idle发生变化的时间点的业务日志，发现15.37 服务程序发生了由于弹性云均衡热点导致的重启（弹性云记录）。

# 故障处理
当时通知运维摘除了这个docker, 之后漂移重建了这个docker.

事后反思：

还是应该第一时间重启服务. （CPU 飚高 → 重启服务）
不能只查看报警时间点业务日志，要根据监控有转折点的时间看业务日志，实际可能看更早的日志。
# 故障分析
故障后排查，发现以下几个条件：

1.CPU idle 下降
2.占用CPU的线程id没有变过
3.jstack多次发现代码一直在get的函数上
4.发现数据结构使用的是weakHashMap
可以推断是发生了Java HashMap死循环的问题。

查看占用CPU高的线程堆栈现场，发现是执行在这个业务代码上.
```java
/**
 * 获取用户的地区列表
 *
 * @param appId
 * @param userAreaParamDto
 * @return
 */
@PostMapping("/area/list")
public ResponseEntity<AppUserAreaResponseDto> userAreaList(@SessionAttribute(ApiConstants.REQUEST_APPID) Long appId,
                                                       @RequestBody UserAreaParamDto userAreaParamDto) {
    if (StringUtils.isEmpty(userAreaParamDto.getUserName())) {
        throw new ServiceException(ApiExceptionEnums.Area.USERNAME_PARAMS_NOT_EXISTS.getCode(),
                ApiExceptionEnums.Area.USERNAME_PARAMS_NOT_EXISTS.getMsg());
    }
 
    Long userId = userManager.getUserIdByName(userAreaParamDto.getUserName());
 
    List<AppUserAreaDto> areas = userManager.getUserAreas(userId, appId);
 
    List<AppUserAreaResponseDto> responseDtos = BeanUtils.mapList(AppUserAreaResponseDto.class, areas); // HERE!!!
 
    return ResponseEntity.success(responseDtos);
}
```
BeanUtils.mapList 是我们的一个继承自org.apache.commons.beanutils.BeanUtils的对象转换的类。跟踪源码发现使用到了外部包orika-core-1.5.0.jar的类
ma.glasnost.orika.metadata.TypeKey .

<img src="ana.png" width = "800" height = "600" align=center />

type是方法输入的类.class,  因为是个通用方法，类似调用还有
```
BeanUtils.mapList(FeatureResponseDto.class, featureDtos)
BeanUtils.mapList(FlagResponseDto.class, flagDtos)
BeanUtils.mapList(RoleResponseDto.class, roleDtos)
BeanUtils.mapList(AreaResponseDto.class, appUserAreaDto)
...
```
而knowTypes 使用了一个多个线程共用的static WeakHashMap (非线程安全类)。 虽然getTypeIndex 方法使用了synchronized 对type加了锁，但是这个锁的粒度只能锁住同一个type, 对于其他type还是可以进入临界区执行knowTypes的get和put，这样就出现HashMap线程不安全的三要素：
- 并发情况存在线程切换
- 多个key,两个key hash到同一个槽
- 触发扩容

从而存在一定几率出现HashMap因为多线程情况出现的死循环，CPU Idle下降的情况。

参考
[耗子哥的HashMap死循环分析](https://coolshell.cn/articles/9606.html)

