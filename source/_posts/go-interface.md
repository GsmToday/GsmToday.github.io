---
title: Go interface源码解析
toc: false
thumbnail: /images/tuboshu.jpeg
date: 2019-01-04 20:59:43
author: NX
categories: 开发语言
tags:
  - GO
---

## Go Interface源码分析

在Go语言中，interface是一个非常重要的概念，不仅可以用来表示任意数据类型的抽象，还可以用来定义一组method集合，实现duck-type programming，到达泛型化编程的目的。所以，深入学习Go中interface的实现很有必要。

<!-- more -->

### Definition

interface的实现在代码runtime\runtime2.go中（1.9.2版本），根据是否包含方法，分为iface和eface两种。

#### eface

```go
type eface struct {
	_type *_type
	data  unsafe.Pointer
}

// Needs to be in sync with ../cmd/link/internal/ld/decodesym.go:/^func.commonsize,
// ../cmd/compile/internal/gc/reflect.go:/^func.dcommontype and
// ../reflect/type.go:/^type.rtype.
type _type struct {
	size       uintptr //type size
	ptrdata    uintptr // size of memory prefix holding all pointers
	hash       uint32  //hash of type;avoids computation in hash table
	tflag      tflag
	align      uint8
	fieldalign uint8
	kind       uint8 // type mask
	alg        *typeAlg
	// gcdata stores the GC type data for the garbage collector.
	// If the KindGCProg bit is set in kind, gcdata is a GC program.
	// Otherwise it is a ptrmask bitmap. See mbitmap.go for details.
	gcdata    *byte
	str       nameOff //string form
	ptrToThis typeOff // type for pointer to this type, may be zero
}
```

eface是对不包含任何方法的数据类型的抽象，如：

```go
x := 1
var y interface{} = x
```

在运行时的内部表示中，y就是eface类型。其中，\_type是对一种具体类型的描述，可以认为是Go语言中所有类型的公共描述。data则是指向真实数据的指针。

#### iface

```go
type iface struct {
	tab  *itab
	data unsafe.Pointer
}

// layout of Itab known to compilers
// allocated in non-garbage-collected memory
// Needs to be in sync with
// ../cmd/compile/internal/gc/reflect.go:/^func.dumptypestructs.
type itab struct {
	inter  *interfacetype //interface type description
	_type  *_type         //origin type
	link   *itab  //hash表头指针
	hash   uint32 // copy of _type.hash. Used for type switches.
	bad    bool   // type does not implement interface
	inhash bool   // has this itab been added to hash?
	unused [2]byte
	fun    [1]uintptr // variable sized
}

type interfacetype struct {
	typ     _type
	pkgpath name
	mhdr    []imethod
}

type imethod struct {
	name nameOff
	ityp typeOff
}
```

iface是包含方法接口的内部表示，通过更复杂的结构itab封装，itab各字段详细描述如下表：

|  字段  |      类型      |                    说明                    |
| :----: | :------------: | :----------------------------------------: |
| inter  | *interfacetype | 对接口声明原型的描述，包括包路径，方法表等 |
| _type  |     *_type     |      对实现该接口的原始真实类型的描述      |
|  link  |     *itab      |         itab hash表对应槽位首地址          |
|  hash  |     uint32     |              copy from _type               |
|  bad   |      bool      |                   标记位                   |
| inhash |      bool      |            是否加入itab hash表             |
| unused |    [2]byte     |                  保留字段                  |
|  fun   |   [1]uintptr   |                 方法地址表                 |

### Example

interface只是对类型的上层抽象，在runtime过程中，还是要映射到具体的类型。下面通过一些例子，观察接口的内部实现和使用方式。

#### 类型转化

##### eface

```go
package main

import (
	"fmt"
)

func main() {
	x := 1
	var y interface{} = x
	fmt.Println(y)
}
```

查看汇编生成的汇编代码

<img src="eface-assemble.png" width = "600" height = "400" align=center title="eface-assemble" />

代码第九行，即接口赋值的实现，调用了runtime.convT2E64方法，其具体实现为：

```go
func convT2E64(t *_type, elem unsafe.Pointer) (e eface) {
	...

	var x unsafe.Pointer
	if *(*uint64)(elem) == 0 {
		x = unsafe.Pointer(&zeroVal[0])
	} else {
		x = mallocgc(8, t, false)  //分配一个8字节的对象
		*(*uint64)(x) = *(*uint64)(elem)
	}
	e._type = t
	e.data = x
	return
}
```

形象一些的内存表示如下图：

<img src="eface-example.png" width = "600" height = "400" align=center title="eface-example" />

##### iface

类似的，对于包含参数的接口转换，runtime包中给出的实现为：

```go
func convT2I(tab *itab, elem unsafe.Pointer) (i iface) {
	t := tab._type
	...

	x := mallocgc(t.size, t, true)
	typedmemmove(t, x, elem)
	i.tab = tab
	i.data = x
	return
}
```

无论iface或者eface都包含类型和值两部分，在类型转换过程中，由于类型信息不会改变，直接通过拷贝指针赋值，而具体的值则根据原始类型的大小，复制一份新的内容。

#### 接口嵌套

接口嵌套允许我们给接口新增特性，实现类似继承的效果。在介绍接口嵌套前，先看下接口类型itab中，接口方法的组织方式。在前文对itab接口的定义中指出，`fun [1]uintptr `是方法地址表，但只包含一个指针，那多个方法的接口如何实现呢？

```go
package main

type MyInterface interface {
	Print()
	Hello()
	World()
	AWK()
}

type MyStruct struct {}
func (me MyStruct) Print() {}
func (me MyStruct) Hello() {}
func (me MyStruct) World() {}
func (me MyStruct) AWK() {}

func Foo(me MyInterface) {
	me.Print()
	me.Hello()
	me.World()
	me.AWK()
}

func main() {
	var me MyStruct
	Foo(me)
}
```

同样反编译Foo函数的调用：

​																											

从上到下，依次调用Print,Hello,World,AWK方法，而方法的地址则分别来源于栈顶指针SP加上相对偏移量 ：SP+0x18+0x30, SP+0x18+0x28, SP+0x18+0x38,SP+0x18+0x20。SP+0x18对应了me的itab地址，而fun相对偏移量可以计算为：8+8+8+4+1+1+2 = 32 = 0x20，而0x20是AWK函数的位置，然后0x28是Hello, 0x30是Print, 0x38是World。这说明：

1. fun[0]地址后依次写入了其他方法的函数指针
2. 函数指针之间按照字典序存放

方法地址的写入参考：runtime\iface.go\additab

了解iface的方法布局，接着看下接口嵌套的实现方式：

```go
package main

type Interface1 interface {
	Print()
	Hello()
}

type Interface2 interface {
	Interface1
	World()
	AWK()
}

type MyStruct struct {}
func (me MyStruct) Print() {}
func (me MyStruct) Hello() {}
func (me MyStruct) World() {}
func (me MyStruct) AWK() {}

func Foo(me Interface2) {
	me.Print()
	me.Hello()
	me.World()
	me.AWK()
}

func main() {
	var me MyStruct
	Foo(me)
}
```

上述代码经过反编译得到的结果和刚刚的例子一致，说明接口嵌套，在实现上是对方法在fun上的平铺。

#### 类型断言

在代码中，常常需要对interface类型进行断言，达到识别接口原生类型的目的。一般有两种写法：

```go
func do(v interface{}) {
    n := v.(int)    // might panic
}

func do(v interface{}) {
    n, ok := v.(int)
    if !ok {
        // 断言失败处理
    }
}
```

第一种写法容易引入panic，第二种方法更加安全，主要原因是底层断言函数，对1个和2个返回值的处理过程略有差异：

```go
func assertI2I(inter *interfacetype, i iface) (r iface) {
	tab := i.tab
	if tab == nil { //为nil直接panic
		// explicit conversions require non-nil interface value.
		panic(&TypeAssertionError{"", "", inter.typ.string(), ""})
	}
	if tab.inter == inter {
		r.tab = tab
		r.data = i.data
		return
	}
	r.tab = getitab(inter, tab._type, false) //第三个参数，不允许类型判断失败，否则panic
	r.data = i.data
	return
}

func assertI2I2(inter *interfacetype, i iface) (r iface, b bool) {
	tab := i.tab
	if tab == nil { //nil接口，直接返回失败
		return
	}
	if tab.inter != inter { //true允许失败，r返回nil
		tab = getitab(inter, tab._type, true)
		if tab == nil {
			return
		}
	}
	r.tab = tab
	r.data = i.data
	b = true
	return
}
```

由于eface类型的接口比较简单，类型断言判断type即可，其实前文go demo里面，关于int类型的断言调用编译器可以完成判断，后文主要以转iface类型的接口为例说明。

当被断言类型为nil时，一个直接panic，另外一个返回false，这是第一点不同。第二点差异主要在getitab方法的最后一个参数上，看下getitab的具体实现：

```go
func getitab(inter *interfacetype, typ *_type, canfail bool) *itab {
	if len(inter.mhdr) == 0 {
		throw("internal error - misuse of itab")
	}

	// easy case
	if typ.tflag&tflagUncommon == 0 {
		if canfail {
			return nil
		}
		name := inter.typ.nameOff(inter.mhdr[0].name)
		panic(&TypeAssertionError{"", typ.string(), inter.typ.string(), name.name()})
	}

	h := itabhash(inter, typ) //根据inter和itab的type计算hash值

	// look twice - once without lock, once with.
	// common case will be no lock contention.
	var m *itab
	var locked int
	for locked = 0; locked < 2; locked++ {
		if locked != 0 {
			lock(&ifaceLock)
		}
		for m = (*itab)(atomic.Loadp(unsafe.Pointer(&hash[h]))); m != nil; m = m.link {//查询itab的hash表中是否已经包含itab和inter关联的itab记录
			if m.inter == inter && m._type == typ {//找到记录
				if m.bad {
					if !canfail { //异常处理
						// this can only happen if the conversion
						// was already done once using the , ok form
						// and we have a cached negative result.
						// the cached result doesn't record which
						// interface function was missing, so try
						// adding the itab again, which will throw an error.
						additab(m, locked != 0, false)
					}
					m = nil
				}
				if locked != 0 {
					unlock(&ifaceLock)
				}
				return m //返回查找结果
			}
		}
	}

   //hash表中未找到记录
	m = (*itab)(persistentalloc(unsafe.Sizeof(itab{})+uintptr(len(inter.mhdr)-1)*sys.PtrSize, 0, &memstats.other_sys)) //分配新的itab
	m.inter = inter
	m._type = typ
	additab(m, true, canfail) //加入itab的hash表
	unlock(&ifaceLock)
	if m.bad {
		return nil
	}
	return m
}

func additab(m *itab, locked, canfail bool) {
	inter := m.inter
	typ := m._type
	x := typ.uncommon()

	// both inter and typ have method sorted by name,
	// and interface names are unique,
	// so can iterate over both in lock step;
	// the loop is O(ni+nt) not O(ni*nt).
	ni := len(inter.mhdr)
	nt := int(x.mcount)
	xmhdr := (*[1 << 16]method)(add(unsafe.Pointer(x), uintptr(x.moff)))[:nt:nt]
	j := 0
	for k := 0; k < ni; k++ { //inter方法列表遍历
		i := &inter.mhdr[k]
		itype := inter.typ.typeOff(i.ityp)
		name := inter.typ.nameOff(i.name)
		iname := name.name()
		ipkg := name.pkgPath()
		if ipkg == "" {
			ipkg = inter.pkgpath.name()
		}
		for ; j < nt; j++ { //typ方法列表遍历
			t := &xmhdr[j]
			tname := typ.nameOff(t.name)
			if typ.typeOff(t.mtyp) == itype && tname.name() == iname {// find the method
				pkgPath := tname.pkgPath()
				if pkgPath == "" {
					pkgPath = typ.nameOff(x.pkgpath).name()
				}
				if tname.isExported() || pkgPath == ipkg {
					if m != nil {
						ifn := typ.textOff(t.ifn)
						*(*unsafe.Pointer)(add(unsafe.Pointer(&m.fun[0]), uintptr(k)*sys.PtrSize)) = ifn // 方法写入新生成的itab方法表
					}
					goto nextimethod
				}
			}
		}
		// didn't find method
		if !canfail {
			if locked {
				unlock(&ifaceLock)
			}
			panic(&TypeAssertionError{"", typ.string(), inter.typ.string(), iname})
		}
		m.bad = true //不匹配的itab
		break
	nextimethod:
	}
	if !locked {
		throw("invalid itab locking")
	}
	h := itabhash(inter, typ)
	m.link = hash[h]
	m.inhash = true
	atomicstorep(unsafe.Pointer(&hash[h]), unsafe.Pointer(m))
}
```

iface的实现中，包含了一个所有itab实例的hash表：

```go
var (
	ifaceLock mutex // lock for accessing hash
	hash      [hashSize]*itab
)
```

itab可以视为一个pair，关联了一个抽象的接口类型interfacetype和一种具体类型实例type的pair。当执行类型断言时，首先根据目标interfacetype和当前接口itab中的type计算hash值，在hash表中，查找是否有相应的记录，如果有，表示之前存在当前接口的真实类型type到interfacetype的转换记录，返回对应的itab。否则，新建一个itab实例，调用additab加入hash表。

additab则首先比对interfacetype和type的方法列表是否一致，如果interfacetype包含type没有的方法，说明这个itab是一个不合法的实例，标记位bad。如果完全符合，则初始化新生成的itab的方法表fun（\*\(\*unsafe.Pointer)(add(unsafe.Pointer(&m.fun[0]), uintptr(k)\*sys.PtrSize)) = ifn ），并加入hash表中。这就解释了前文iface fun列表的实现原理。其次，由于方法列表按照字典序排列，所以校验方法是否匹配的两层for循环其实只要O(m+n)而不是O(mn)的复杂度。

itab可以说是Go语言duck-typing的底层原理，其interfacetype和itab.type关联为type的设计，满足一个实例实现多个接口的功能和一个接口多个实现实例的功能。所以，下面实例的断言都是成功的：

```go
package main

import "fmt"

type Interface1 interface {
	Print()
}

type Interface2 interface {
	Print()
}

type Interface3 interface {
	Hello()
}

type Mystruct struct {}

func (strct Mystruct) Print() {}

func (strct Mystruct) Hello() {}

func main() {
	var s Mystruct
	var i1 Interface1
	i1 = s
	i2 := i1.(Interface2) //ture
	i3 := i1.(Interface3) //true
	fmt.Print(i2, i3)
}
```



#### nil判断

代码中可能需要判断一个接口是否为空值，最常见的就是error接口：

```go
if err != nil {
    //
}
```

interface并不是一个指针，它的底层实现由两部分组成，一个是类型，一个值，也就是类似于：(Type, Value)。只有当类型和值都是`nil`的时候，才等于`nil`

```go
func do() error {   // error(*doError, nil)
  var err *doError
  return err  // nil of type *doError
}

func main() {
  err := do()
    fmt.Println(err == nil) //false
}
```

```go
func do() *doError {  // nil of type *doError
  return nil
}

func wrapDo() error { // error (*doError, nil)
  return do()       // nil of type *doError
}

func main() {
  err := wrapDo()   // error  (*doError, nil)
  fmt.Println(err == nil) // false
}
```
