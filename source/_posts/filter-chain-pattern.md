---
title: 责任链模式实践
toc: false
banner: /images/tortoise.jpg
date: 2017-10-22 21:46:57
author: GSM
tags:
  - Design Pattern
---

最近参与的项目开发了大量RPC接口，并且需要针对所有RPC接口开发接入公司方法监控的埋点代码。开发RPC方法的监控埋点代码有两种方式：

1、在每个RPC方法体内添加埋点代码。

这是最简单直观的开发方式，但是会造成大量重复冗余的代码。假设项目有m个RPC类，每个类有n个方法，就要开发m*n个监控埋点代码，而监控埋点代码除了方法监控key之外没有任何不同的。显然这种方式并不优雅，耦合度很高。

2、使用**责任链模式**处理所有RPC的调用请求。

<!-- more -->

责任链模式用一个调用链组织所有过滤器类，每一个调用请求从过滤器类间依次传递，每个过滤器可以选择是否对调用请求执行自己的操作。因此可以实现一个监控请求的过滤器，该过滤器专门实现针对所有RPC方法调用的监控埋点。

这种方法实现只在代码集中的一处(过滤器类)动态添加监控，而不是在每个RPC接口都添加一段重复的监控埋点代码。提高了代码复用性, 统一添加了方法监控。

```java
/**
 *为方法监控添加埋点代码的过滤器类
 */
public class InvokeExceptionFilter extends AbstractFilter{
    @Override
    public ResponseMessage invoke(RequestMessage request) {
        ResponseMessage responseMessage = MessageBuilder.buildResponse(request);

        String requestClass = request.getClassName();
        String requestMethod = request.getMethodName(); // 调用方法名

        String clazzNameStr = StringUtils.substring(requestClass,requestClass.lastIndexOf(".")); //RPC interface名称
        String alias = request.getInvocationBody().getAlias();// 用于区分业务
        String methodWatcherKey = clazzNameStr+"-Alias:+"+alias+"::"+requestMethod;

        registerWatcher(methodWatcherKey)// 开始方法监控
        try {
            // 调用链自动往下层执行 request.getInvocationBody().getAlias()
            responseMessage = this.getNext().invoke(request);
        }catch (Exception e){
            watcherCalculate(methodWatcherKey) // 统计方法可用率
        }finally {
            registerInfoEnd(methodWatcherKey); // 此方法监控结束
        }
        return responseMessage;
    }
}

```
## 责任链模式初探
> Chain of Responsibility gives more than one object an opportunity to handle a request by linking receiving objects together. by GoF

责任链模式是一种行为模式。责任链允许多个类参与处理一个请求。多个互相独立的类(过滤器)组成一个调用链，请求从调用链的第一个过滤器传递给后一个过滤器，直到这个请求满足某个过滤器的处理条件被处理，至此调用链执行完毕。

<img src="http://java.dzone.com/sites/all/files/chain_of_resp_pattern.PNG" alt="chain_of_resp_pattern" title="chain_of_resp_pattern" width="600" height="300" />

## 使用场景
解耦请求发送者和请求接收者，让多个过滤器有机会去处理请求。具体分为以下三个使用场景：

1、多个对象都可以处理一个请求，请求的处理者不需要是一个专门的对象。

2、多个对象都可以处理一个请求，请求的处理者在运行时决定。

3、请求没有被处理也是可接受的。

## 使用范例
除了前文提到的统一监控埋点代码，还有windows系统处理鼠标或键盘产生的事件使用到了责任链模式。另外，异常统一处理也可以使用此模式。Servlet 的过滤器就是根据责任链模式设计的。

## 如何使用责任链模式
责任链模式由以下两个角色组成

- 抽象过滤器角色
    抽象过滤器定义了
        - 一个处理请求的接口
        - 下一个过滤器的指针
        - 获取和设置下一个过滤器的接口

- 具体过滤器角色
    具体过滤器接到请求后，针对请求判断是否满足自己处理条件，可以选择将请求处理掉，或者将请求传给下一个过滤器。
```java
public interface Filter {
    ResponseMessage invoke(RequestMessage var1);
}

/**
 *抽象过滤器角色
 */
public abstract class AbstractFilter implements Filter {

    private Filter next; //下一个过滤器

    abstract public ResponseMessage invoke(RequestMessage request); //调用RPC服务

    /**
     * get下一层过滤器
     */
    protected Filter getNext() {
        return next;
    }

    /**
     * Sets next下一层过滤器
     */
    protected void setNext(Filter next) {
        this.next = next;
    }
    ...
}
```
## 有可能引起的问题
责任链模式也有缺点，这与if…else…语句的缺点是一样的，那就是在找到正确的处理类之前，所有的判定条件都要被执行一遍，当责任链比较长时，性能问题是一个值得考虑的问题。

## 参考资料
1. https://dzone.com/articles/design-patterns-uncovered-chain-of-responsibility

2. http://blog.csdn.net/eson_15/article/details/52126811




