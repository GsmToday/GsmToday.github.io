---
title: Java8函数式接口
toc: false
thumbnail: /images/catfeet.jpg
date: 2017-10-17 21:36:38 
tags:
  - Java
author: GSM
---

Java8引入了“行为参数化”的理念。为了实现行为参数化，java8提出**函数式接口**和**Lambda表达式**。本文首先会讲讲什么是函数式接口，然后会讲到java8预定义的四种核心函数式接口，以及使用这四种接口处理问题的demo。同时，本文还会使用大量的用Stream处理集合数据的例子。

<!-- more -->

# 函数式接口 functional interfaces

函数式接口：

- 函数式接口是一种特殊的SAM类型(Single Abstract Method), 即只定义一个抽象方法的接口。
- 使用`@FunctionalInterface`标注一个接口即表示该接口是一个函数式接口，如果你用`@FunctionalInterface`定义了一个接口，而它却不是函数式接口的话，编译器将返回一个提示原因的错误。
- Lambda表达式是函数式接口的实例。以函数式接口为参数的方法，可以在调用时使用Lambda表达式作为参数。

之所以java8设计函数式接口，主要目的是因为：函数式接口的抽象方法可以使用Lambda表达式作为输入参数。本质上讲，函数式接口和Lambda表达式将`行为参数化`成为了可能。

# 四种核心接口
Java8预定义了大量的函数式接口，这样客户端可以直接使用。这些预定义的函数式接口定义在`java.util.function`下，通常分为以下四种。

| 函数式接口       | 参数及返回类型        | 用途                         |
| ------------- |:-------------:| -----:|
| Consumer<T>  | void accept(T t) | 消费型接口，接受一个参数，没有返回值|
| Supplier<T>  | T get()    | 供给型接口，不接受参数，有一个返回值  |
| Function<T,R>| R apply(T t) |功能型接口，接受一个参数，处理后返回一个值|
|Predicate<T> | Boolean test(T t)| 断言性接口，接受一个参数，返回判断结果boolean|

## Consumer  
顾名思义，`Consumer`接口使用场景为当一个对象需要被“消费”掉的时候。即这个对象作为方法的输入参数被执行某些操作，而且方法不做任何返回。打印操作就是一个典型的消费操作。

`Consumer` 源码：
```java
@FunctionalInterface
public interface Consumer<T> {
    void accept(T t);
}
```

使用`consumer`执行打印的demo
```java
    public class ConsumerExample{
        public static void main(String args[]){
            Consumer<Integer> consumer= i-> System.out.print(" "+i);

            List<Integer> integerList=Arrays.asList(new Integer(1), new Integer(2), new Integer(3),
            new Integer(4), new Integer(5), new Integer(6));

            printList(integerList, consumer);
        }
        public static void printList(List<Integer> listOfIntegers, Consumer<Integer> consumer){
            for(Integer integer:listOfIntegers){
                consumer.accept(integer);
            }
        }
    }
```

另外，`Consumer`的doc提到一句，

> Consumer is expected to operate via side-effects.

`Consumer`接口可以执行带有副作用的操作，即`Consumer`的操作可能会更改输入参数的内部状态。实践中，我们可以使用Consumer来更改对象内部状态。

例如Stream中使用率很高的`forEach`方法。`forEach`方法是java8新引入的内部遍历(有关内部遍历和外部遍历的区别，可以参见[link](https://gsmtoday.github.io/2017/09/10/Lambda/)).

举个例子：根据获取到的系统所有模块列表，创建一个map，map的key是模块id, value是模块对象。

```java
 default Map<Integer, Module> getModules() {
        Map<Integer, Module> moduleMap = new HashMap<>();
        List<? extends Module> moduleMapList =  getAllModulePrototype(); // 获取系统所有模块列表

        if (CollectionUtils.isNotEmpty(moduleMapList)) {
            moduleMapList.forEach(module -> moduleMap.put(module.getId(), module));
        }

        return  moduleMap;
    }
```

## Supplier
当某个场景不需要输入但是需要输出的时候，就可以用到`Supplier`。

`Consumer` 源码：
```java
@FunctionalInterface
public interface Supplier<T> {
    /**
     * Gets a result.
     * @return a result
     */
    T get();
}
```

对于`Supplier`，可以理解为利用它生产一个新的对象。例如通过实现`Supplier`接口，可以自己来控制流的生成(generater方法)。

```java
//生成num个整数,并存入集合
public List<Integer> getNumList(int num, Supplier<Integer> sup) {
    List<Integer> list = new ArrayList<>();
        for (int i = 0; i < num; i++) {
            Integer n = sup.get();
            list.add(n);
        }
    return list;
}
public static void main(String[] args) {
    //10个100以内的随机数
    List<Integer> numList = getNumList(10, () -> (int) (Math.random() * 100));
    for (Integer num : numList) {
        System.out.println(num);
    }
}
```
## Function
`Function`接口主要用于**映射**场景. A类型的对象作为输入参数被执行Lambda表达式操作，最后转换为B类型的对象返回。

```java
@FunctionalInterface
public interface Function<T, R> {
    R apply(T t);
}
```

`Function`接口被用在Stream的map方法的输入参数，map方法把input Stream的每一个元素，映射成output Stream的另外一个元素。

Stream的`map`方法:
```java
<R> Stream<R> map(Function<? super T, ? extends R> mapper);
```

举例，将列表的数字转换成平方数
```java
List<Integer> nums = Arrays.asList(1,2,3,4);
List<Integer> squareNums = nums.stream().map(n ->n*n).collect(Collectors.toList);
```

再比如：
获取Person对象的姓名
```java
List<Person> persons = Arrays.asList(
                new Person("gsm", 26),
                new Person("nx", 24),
        );

        String name = persons.stream()
                .filter(x -> "gsm".equals(x.getName()))
                .map(Person::getName)  //convert stream to String
                .findAny()
                .orElse("");

        System.out.println("name : " + name);
```

```
输出：name : gsm
```
## Predicate
`Predicate`的使用场景为：一个对象需要被评估是否满足某条件，并且返回一个boolean型作为评估结果。

`Predicate`源码：
```java
package java.util.function;
import java.util.Objects;
@FunctionalInterface
public interface Predicate<T> {
    boolean test(T t);
}
```

使用demo：自己定义一个以`Predicate`为参数的的方法。
```java
public int sumAll(List<Integer> numbers, Predicate<Integer> p) {
    int total = 0;
    for (int number : numbers) {
        if (p.test(number)) {
            total += number;
        }
    }
    return total;
}
sumAll(numbers, n -> true); // 求数字列表的总和
sumAll(numbers, n -> n % 2 == 0); //求数字列表的偶数总和
sumAll(numbers, n -> n > 3);//求数字列表大于3的数字总和
```

再比如Stream中使用率很高的`filter`方法。`filter`方法返回一个由满足predicate条件的元素组成的列表。

```java
Stream<T> filter(Predicate<? super T> predicate);
```

使用filter示例,找出名称为自定义模块2的模块。

```java
        List<Module> moduleList = {new Module("自定义模块1"), new Module("自定义模块2",new Module("自定义模块3")};

        List<Module> result = richModuleList.stream().filter(
                richModule -> richModule.getName().equals("自定义模块2")).collect(Collectors.toList());
```