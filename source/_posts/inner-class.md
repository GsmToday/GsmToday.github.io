---
title: Java内部类详解
toc: false
thumbnail: /images/shulan.jpg
author: GSM
date: 2017-09-07 22:42:28
tags:
  - Java
categories: 学习积累
---

## What
Sun公司在JDK1.1以后的版本中引入了内部类的概念：一个类可以定义在另一个类之中。这个嵌套着另一个类的类叫做"外部类（outer class）", 被嵌套的类叫做内部类（inner class）.

<!-- more-->

内部类示例：

```java
public class OuterClass {
  private String name ;
  private int id;

  public String getName() {
  return name;
  }

  public void setName(String name) {
  this.name = name;
  }

  public int getId () {
  return id ;
  }

  public void setId (int id ) {
  this. id = id ;
  }

  class InnerClass{
       public InnerClass(){
             name = "testName";
             age = 1;
         }
   }
}
```
可以看出当引入内部类后，外部类的结构变为了：

- 外部类
    + 成员变量
    + 成员函数
    + 内部类

### 匿名内部类
没有类名的内部类就是匿名内部类（anonymous inner class）.我们通常同时声明和实例化一个匿名内部类。

语法：
```java
FatherClass anonymousInnerClassObject = new FatherClass() {
   public void myMethod() {
      ........
      ........
   }   
};
```

在定义一个匿名内部类之前，需要先定义出这个匿名内部类的父类。
```java
abstract class FatherClass {
   public abstract void myMethod();
}
```


匿名内部类相当于这个父类的实现。

```
public class  Outer_class {
 {

   public static void main(String args[]) {
      FatherClass inner = new FatherClass() {
         public void myMethod() {
            System.out.println("This is an example of anonymous inner class");
         }
      };
      inner.myMethod();
   }
}
```

Note : 我们给匿名内部类传递参数的时候，若该形参在内部类中需要被使用，那么该形参必须要为final。也就是说：当所在的方法的形参需要被内部类里面使用时，该形参必须为final。[为什么必须是final,具体请参考](http://www.cnblogs.com/chenssy/p/3390871.html) 简单来说是因为：内部类并不是直接调用方法传递的参数，而是利用自身的构造器对传入的参数进行备份，自己内部方法调用的实际上时自己的属性而不是外部方法传递进来的参数。改了外部方法参数，并不会影响内部参数。为了保持参数的一致性，就规定使用final来避免形参的不改变。

## Why

为什么要使用内部类？

- 多重继承
- 传递行为
- 隐藏接口的实现细节

### 多重继承

多重继承指的是一个类可以同时从多于一个的父类那里继承行为和特征，然而我们知道Java为了保证数据安全，它只允许单继承。如果父类为抽象类或者具体类，那么我就仅能通过内部类来实现多重继承了。

```java
public class Son {

    /**
     * 内部类继承Father类
     */
    class Father_1 extends Father{
        public int strong(){
            return super.strong() + 1;
        }
    }

    class Mother_1 extends  Mother{
        public int kind(){
            return super.kind() - 2;
        }
    }

    public int getStrong(){
        return new Father_1().strong();
    }

    public int getKind(){
        return new Mother_1().kind();
    }
}
```

### 传递行为
Jdk1.8 之前，Java语言发展这么多年来一直是“重对象，轻函数”的设计理念。函数对于Java这种依赖于对象存在的语言似乎不那么重要，因此Java语言设计者们在设计时也不那么考虑函数。比如Java里无法将函数作为函数的输入参数传递， **只能借助匿名内部类这种方式**

例如线程池处理代码：

```java
 threadPoolTaskExecutor.execute(new Runnable() {
            @Override
            public void run() {
                ...//代码逻辑

            }
        });
    }
```

### 隐藏接口的实现细节

内部类还可以实现代码的隐藏，将一个类放在另一个类之间，隐藏对一个接口的实现细节。内部类提供了更好的封装，除了该外围类，其他类都不能访问。

## 解惑

>  嵌套类和内部类的区别？

嵌套类

- 非静态嵌套类， which is 内部类. 内部类是嵌套类的一种。
- 静态嵌套类， 已经很少用了。      

> 为什么内部类很特殊【1】？

内部类的实例可以获取外部类成员变量的消息，即使是私有成员变量也是可以的。

> 内部类和静态嵌套类的区别？

内部类的实例可以获取外部类成员变量的消息，即使是私有成员变量也是可以的。而静态嵌套类不能。

内部类不能有 static 数据和 static属性。因为静态域是不能访问非静态的方法和成员变量，如果inner class是有静态的,就违背了【1】

> 什么时候使用内部类?

知道这个问题十分必要，因为错误的场合使用内部类会导致代码难以理解和维护。
首先是可以多重继承。内部类可以继承一个与外部类无关的类，保证了内部类的独立性，正是基于这一点，多重继承才会成为可能。

其次，一般情况由于面向对象设计，一个类具有专有的功能，但是如果这个类还需要另外一个类的信息与之交互，比如类方法的参数希望是一种行为，那么就可以使用内部类。

## 参考
[chenssy's blog](http://www.cnblogs.com/chenssy/p/3389027.html)