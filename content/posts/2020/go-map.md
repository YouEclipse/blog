---
title: "[源码阅读] Go 1.14 Map"
date: 2020-04-21T20:53:00+08:00
tags: ["golang", "map", "源码"]
categories: ["golang", "源码"]
draft: false
---

## 前言

这是我第一次写源码分析的文章，在写这篇文章之前，我阅读过一些写的很好 Go 源码分析的文章，比如本文参考的曹春辉老师的[golang-notes](https://github.com/cch123/golang-notes/blob/master/map.md)和饶大的[码农桃花源](https://qcrao91.gitbook.io/go/map)系列。但是，而随之时间的推移，Go 版本迭代，源码还是会有一些细微的变动；再者，我认为看别人的文章，不如自己写一篇理解地深刻。 珠玉在前，本文难免有不足，望见谅。

由于大部分的 Go 程序跑在 linux 下，因此平台相关的代码也以 `linux/amd64` 为准，
这是我在阅读源码时的 go 版本

```
% go version
go version go1.14 linux/amd64
```

为了方便查阅源码，我同时也附上了文章中代码 在 github 仓库的链接。

## 哈希函数的初始化

Golang 的 map 的实现是 Hash table,那么必然是需要有哈希函数，那么它是怎么来的呢？
在源码目录`runtime/alg.go`，我们可以找到一个函数`alginit`

```golang
func alginit() {
    // 如果 CPU 架构支持 AES hash，则初始化 AES hash
if (GOARCH == "386" || GOARCH == "amd64") &&
	cpu.X86.HasAES && // AESENC
	cpu.X86.HasSSSE3 && // PSHUFB
	cpu.X86.HasSSE41 { // PINSR{D,Q}
	initAlgAES()
	return
}
if GOARCH == "arm64" && cpu.ARM64.HasAES {
	initAlgAES()
	return
}
getRandomData((*[len(hashkey) * sys.PtrSize]byte)(unsafe.Pointer(&hashkey))[:])
hashkey[0] |= 1 // make sure these numbers are odd
hashkey[1] |= 1
hashkey[2] |= 1
hashkey[3] |= 1
}
```

这个函数在程序启动时会被调用，根据源码，可以很清晰的看到，**当 cpu 架构是 `x86` 或者 `amd64` 的时候，且 cpu 支持 `AESENC` 等指令，或者 `arm64` 架构下支持`AESE`和`AESMC`指令时**，就使用 AES Hash 作为哈希算法，如果不是支持，将会进入`getRandomData`函数，这个函数最终是使用的`memhash`,
调用路径是`alginit`->`getRandomData`->`extendRandom`->`memhash`。

我在看源码时，一直有一个疑问，AES 不是对称加密算法吗？怎么又变成了哈希算法？事实上，这二者是不同的东西，我们常见的 `MD5`,`SHA-1`,`SHA-256` 等，都属于加密型哈希，是不可逆的；而非加密型哈希，常见的有`CRC32`,一般用于校验消息的完整性或者不关注哈希碰撞的概率的场景。**AES 哈希只是因为用了`AES`相关的 CPU 指令**，实际上和对称加密的那个`AES`是不一样的，关于`AES Hash`的资料不多，本文参考中附有两篇相关论文。

## map 的底层结构

我们创建一个 map，一般是通过`make(map[k]v, hint)`函数创建，而这个函数在编译期，会变成`func makemap(t *maptype, hint int, h *hmap) *hmap`， 位于`runtime/map.go:303`,这里可以看到，当我们创建一个 map 的时候，实际上是创建了一个 `×hmap`指针，hmap 才是 map 真正的底层结构。

这里我们先看看`hmap`的结构

```golang
type hmap struct {

	count     int // map的大小，调用len()函数是返回的就是count的值
	flags     uint8
	B         uint8  // bucket 数量的2的对数 最大数量为 负载因子×2^B
    noverflow uint16 // overflow的近似数
	hash0     uint32 // hash seed

	buckets    unsafe.Pointer // bucket 数组，如果元素个数为0，则为nil
	oldbuckets unsafe.Pointer // 只有在扩容的时候不是nil,大小是buckets的1/2
    nevacuate  uintptr        // 指示扩容进度，小于这地址的bucket是已经迁移的
	extra *mapextra // 仅在map的key和value都不包含指针且可以内联的情况下，用来存储overflow bucket
}
```

其中`bucket`的结构如下，包含一个 8 个长度的数组

```golang

type bmap struct {
	tophash [bucketCnt]uint8
}
```

但是，在编译过程中，它会变成一个新的结构，相关编译的细节在 [`cmd/compile/internal/gc/reflect.go`](https://github.com/golang/go/blob/go1.14/src/cmd/compile/internal/gc/reflect.go#L82)中的`func bmap(t *types.Type) *types.Type` ,最终是这样一个结构

```go
type bmap struct {
	// 每个元素hash值的高8位，如果tophash[0] < minTopHash
	// 则它是bucket(扩容时)搬迁的状态
	topbits  [8]uint8
	// 在内存中，key和elem是 key/key/key.../elem/elem/...排列的
	// 因为这样在key和value长度不同时可以消除 key/elem/key/elem/..这种形式排列
	// 所需的 padding 所占用的额外的存储空间
    keys     [8]keytype
	elems    [8]elemtype
	//当bucket 溢出时，指向溢出的bucket的指针
    overflow uintptr
}
```

- topbits 保存了每个元素 hash 的高八位，这样寻找 key 的时候只需要对前 8 位做判断，可以加快查询速度
- keys 和 elems 是实际上通过指针计算偏移量来访问的，并且是按照 key/key/key.../elem/elem/... 排列的，这样可以省略掉 padding 字段，节约内存
- 在 key 和 value 都不是指针切长度都小于 128 的时候，会将 bmap 标记为不含指针，这样就不会被 gc 扫描。overflow 虽然是个指针，但是并不是指针类型，实际上 overflow 保存在 hmap 结构的 extra 字段中。

```go

type mapextra struct {

	// 如果key和value都不包含指针且可以被内联(<=128 byte)
	// 使用extra来存储overflow bucket,可以避免被GC扫描整个map
	// 然而，bmap.overflow也是个指针，这时候我们把这些overflow的bucket都放在extra

	// overrflow 包含的是overflow的bucket
	overflow    *[]*bmap
	//扩容的时候保存旧的overflow
	oldoverflow *[]*bmap

	// 指向空的overflow bucket
	nextOverflow *bmap
}

```

## map 的创建

一般情况下，我们都是通过 `make` 函数创建 map，编译器会调用`makemap` 方法进行初始化
特别的情况，比如创建时指定的大小<=8 的或者没有指定 map 大小的时候，则会调用`makemap_small`来创建

```go
func makemap_small() *hmap {
	h := new(hmap)
	h.hash0 = fastrand()
	return h
}


// 如果编译器认为map或者说第一个bucket可以创建在栈上，h和bucket可能都是非空
// 如果h !=nil，那么map可以直接在h中创建
// 如果 h.buckets !=nil，则其指向的bucket可以作为第一个bucket来使用
func makemap(t *maptype, hint int, h *hmap) *hmap {
	//如果对应map的bucket size × hint 溢出或者超过可以分配的最大内存
	//将hint置为0
	mem, overflow := math.MulUintptr(uintptr(hint), t.bucket.size)
	if overflow || mem > maxAlloc {
		hint = 0
	}

	// initialize Hmap
	if h == nil {
		h = new(hmap)
	}
	//随机哈希种子
	h.hash0 = fastrand()

	// 根据hint的大小，找到一个低于负载因子的B
	// 当hint < 0 的时候，因为 hint < 1 , overLoadFactor(计算是否负载因子的函数)直接返回false
	B := uint8(0)
	for overLoadFactor(hint, B) {
		B++
	}
	h.B = B

	// 分配初始的 hash table
	// 如果B==0,h.buckets 会在 mapassign(赋值) 的时候来创建
	// 如果 hint 很大，对这部分内存归零会花相对较长的时间
	if h.B != 0 {
		var nextOverflow *bmap
		h.buckets, nextOverflow = makeBucketArray(t, h.B, nil)
		if nextOverflow != nil {
			h.extra = new(mapextra)
			h.extra.nextOverflow = nextOverflow
		}
	}

	return h
}
```

//TODO: maptype

实际上，用哪个函数，还取决于**编译器逃逸分析的结果**，参考相关代码`cmd/compile/internal/gc/walk.go:1218`
只有在 map 发生逃逸分配在堆上，且满足前面所说的的条件，才会调用`makemap_small`

## map 的增删改查

### 增/改(mapassign) - map 的赋值

map 的赋值函数是由编译器决定的，取决于 key 的类型和大小，参考相关代码`cmd/compile/internal/gc/walk.go:2495`的`mapfast`方法，对于不同的`mapassign`函数，差异不大，这里我们用 mapassign 举例

```go
// 和mapaccess函数类似，但在key没有找到的时候，会为key分配一个新的槽位
func mapassign(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	//如果map没有初始化就去赋值，则发生panic
	if h == nil {
		panic(plainError("assignment to entry in nil map"))
	}
	//go run/build -race 检测 datarace 的时候才会执行，这里不做探讨
	if raceenabled {
		callerpc := getcallerpc()
		pc := funcPC(mapassign)
		racewritepc(unsafe.Pointer(h), callerpc, pc)
		raceReadObjectPC(t.key, key, callerpc, pc)
	}
	// go run/build -msan 时执行
	if msanenabled {
		msanread(key, t.key.size)
	}
	//写的时候map已经是赋值中的状态，同样会panic，也直接说明map不是goroutine安全的，不能并发写
	if h.flags&hashWriting != 0 {
		throw("concurrent map writes")
	}
	//调用对应的哈希算法
	hash := t.hasher(key, uintptr(h.hash0))


	// 将 hashWriting 字段设为正在写的状态，
	// 因为此时我们还没有完成写入 t.hasher 可能会panic

	h.flags ^= hashWriting

	//如果h.buckets 没有初始化，分配第一个bucket，这里在前面介绍makemap函数有提到
	if h.buckets == nil {
		h.buckets = newobject(t.bucket) // newarray(t.bucket, 1)
	}

again:
	// 计算低B位的 hash,用来选择对应的bucket
	// bucketMask -> 1<<h.B - 1
	bucket := hash & bucketMask(h.B)
	// 如果正在扩容中，则进行扩容
	if h.growing() {
		growWork(t, h, bucket)
	}
	//指针运算，bucket 的内存的地址
	// pos = start + bucket*bucketsize
	b := (*bmap)(unsafe.Pointer(uintptr(h.buckets) + bucket*uintptr(t.bucketsize)))
	//计算高8位的hash
	top := tophash(hash)

	var inserti *uint8
	var insertk unsafe.Pointer
	var elem unsafe.Pointer
bucketloop:
	for {
		//遍历bucket的8个元素
		for i := uintptr(0); i < bucketCnt; i++ {
				// b.tophash[i] != top 则有可能是可空的槽位
			if b.tophash[i] != top {
				//如果槽位是空的且没有被占用，则记录下来，
				//因为key要尽可能插入在前面的空槽位
				if isEmpty(b.tophash[i]) && inserti == nil {
					inserti = &b.tophash[i] //记录tophash 插入的位置
					insertk = add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
					elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				}
				// 如果只有这个槽位是空的，其他后续的槽位包括overflow都已经满了
				// 跳出bucketloop
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			//如果key是指针类型则取出他的值来比较
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			// 如果两个key的值不一样，即可能发生了哈希碰撞
			if !t.key.equal(key, k) {
				continue
			}
			// 如果key已经存在了，则update
			if t.needkeyupdate() {
				typedmemmove(t.key, k, key)
			}
			elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			goto done
		}
		// 如果bucket的8个槽位都没有可以插入或者更新的，去overflow里找
		ovf := b.overflow(t)
		//如果overflow为nil，说明已经到了bucket链表的末端
		if ovf == nil {
			break
		}
		// 赋值为bucket链表的下一个元素，继续寻找
		b = ovf
	}

	// 没有找到key，分配新的空间

	// 如果过已经达到了负载因子(count/2^B>6.5)或者overflow的bucket太多了
	// 并且不在扩容中，则开始扩容
	if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
		hashGrow(t, h)
		goto again // Growing the table invalidates everything, so try again
	}

	// 前面未找到可以放这个tophsah的位置
	if inserti == nil {
		// 所有的bucket都满了 创建一个新的overflow bucket
		newb := h.newoverflow(t, b)
		inserti = &newb.tophash[0]
		insertk = add(unsafe.Pointer(newb), dataOffset)
		elem = add(insertk, bucketCnt*uintptr(t.keysize))
	}

	// 把新的key和elem 插入到对应的位置这个槽位是空的，其他槽位包括over
	if t.indirectkey() {
		kmem := newobject(t.key)
		*(*unsafe.Pointer)(insertk) = kmem
		insertk = kmem
	}
	if t.indirectelem() {
		vmem := newobject(t.elem)
		*(*unsafe.Pointer)(elem) = vmem
	}
	typedmemmove(t.key, insertk, key)
	*inserti = top
	// map长度+1
	h.count++

done:
	if h.flags&hashWriting == 0 {
		throw("concurrent map writes")
	}
	h.flags &^= hashWriting
	if t.indirectelem() {
		elem = *((*unsafe.Pointer)(elem))
	}
	return elem
}
```

看完这段代码 我们会发现，我们并没有把 elem 写入对应的区域，实际上，**编译器会额外生成汇编指令，将值放入该地址中**。

### 删(mapdelete)-删除 map 的元素

map 的删除是通过 `delete()`函数来删除元素的，在编译后，实际上是执行`mapdelete`函数来删除的，它的大部分逻辑和`mapassign`类似，
这里就不详细注释说明了

```go
func mapdelete(t *maptype, h *hmap, key unsafe.Pointer) {
	// -race
	if raceenabled && h != nil {
		callerpc := getcallerpc()
		pc := funcPC(mapdelete)
		racewritepc(unsafe.Pointer(h), callerpc, pc)
		raceReadObjectPC(t.key, key, callerpc, pc)
	}
	// -msan
	if msanenabled && h != nil {
		msanread(key, t.key.size)
	}

	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return
	}
	// 如果此时map正在写，会panic，所以，删除也不是并发安全的
	if h.flags&hashWriting != 0 {
		throw("concurrent map writes")
	}

	hash := t.hasher(key, uintptr(h.hash0))

	// Set hashWriting after calling t.hasher, since t.hasher may panic,
	// in which case we have not actually done a write (delete).
	h.flags ^= hashWriting

	//根据最后B位找到对应的bucket
	bucket := hash & bucketMask(h.B)
	//如果要扩容，则先扩容
	if h.growing() {
		growWork(t, h, bucket)
	}
	b := (*bmap)(add(h.buckets, bucket*uintptr(t.bucketsize)))
	bOrig := b
	top := tophash(hash)
search:
	for ; b != nil; b = b.overflow(t) {
		//遍历8个槽位
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top {
				//这个bucket是空的，而且后面没有别的空的bucket了
				if b.tophash[i] == emptyRest {
					break search
				}
				continue
			}
			//计算k在bucket的地址
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			k2 := k
			if t.indirectkey() {
				k2 = *((*unsafe.Pointer)(k2))
			}
			//如果发生哈希冲突，下一个
			if !t.key.equal(key, k2) {
				continue
			}
			// 如果key是指针则情况，清空key的内容
			if t.indirectkey() {
				*(*unsafe.Pointer)(k) = nil
			} else if t.key.ptrdata != 0 {
				memclrHasPointers(k, t.key.size)
			}
			//计算elem的地址
			e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			if t.indirectelem() {
				*(*unsafe.Pointer)(e) = nil
			} else if t.elem.ptrdata != 0 {
				memclrHasPointers(e, t.elem.size)
			} else {
				memclrNoHeapPointers(e, t.elem.size)
			}
			//将对应的槽位更新为空
			b.tophash[i] = emptyOne

			// 如果bucket的后续都是空的槽位了，那么将其设置成emptyOne,这样下次访问的时候就可以不需要再去访问后续的槽位了
			// 这段代码放在另一个函数会更加优雅，但是for循环不会被内联，这样会增加一次函数调用的开销
			if i == bucketCnt-1 {
				//后续有非空的槽位
				if b.overflow(t) != nil && b.overflow(t).tophash[0] != emptyRest {
					goto notLast
				}
			} else {
				if b.tophash[i+1] != emptyRest {
					goto notLast
				}
			}
			for {
				b.tophash[i] = emptyRest
				if i == 0 {
					if b == bOrig {
						break // 结束循环
					}
					// 找到前一个bucket的最后一个槽位，continue
					c := b
					for b = bOrig; b.overflow(t) != c; b = b.overflow(t) {
					}
					i = bucketCnt - 1
				} else {
					i--
				}
				if b.tophash[i] != emptyOne {
					break
				}
			}
		notLast:
			h.count--
			break search
		}
	}
	//并发读写校验
	if h.flags&hashWriting == 0 {
		throw("concurrent map writes")
	}
	h.flags &^= hashWriting
}
```

### 查(mapaccess)-map 的访问

在前文中的`mapassign`其实就已经包含了部分 map 查找的逻辑，实际上源码中`mapaccess`函数的实现也类似，**通过 hash 的后 `hmap.B` 位来确认 bucket,通过前 `8` 位确认 key 的位置**。源码中有很多中`mapaccess`函数，他们的作用类似，只是适用不同的场景

`val := m[key]` ==> `mapaccess1`

`val,ok := m[key]` ==> `mapaccess2`

`for k,v := range m{}` ==> `mapaccessK`

这里我们以`mapaccess1`举例：

```go
// mapaccess1 returns a pointer to h[key].  Never returns nil, instead
// it will return a reference to the zero object for the elem type if
// the key is not in the map.
// NOTE: The returned pointer may keep the whole map live, so don't
// hold onto it for very long.
//
func mapaccess1(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	// -race
	if raceenabled && h != nil {
		callerpc := getcallerpc()
		pc := funcPC(mapaccess1)
		racereadpc(unsafe.Pointer(h), callerpc, pc)
		raceReadObjectPC(t.key, key, callerpc, pc)
	}
	// -msan
	if msanenabled && h != nil {
		msanread(key, t.key.size)
	}
	//map为nil或者长度为0,返回未找到
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return unsafe.Pointer(&zeroVal[0])
	}
	//如果写的时候的读，会panic
	if h.flags&hashWriting != 0 {
		throw("concurrent map read and map write")
	}
	hash := t.hasher(key, uintptr(h.hash0))
	//取决于B的大小
	m := bucketMask(h.B)
	// hash&m 按位与,定位到对应bucket的地址
	b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
	// h.oldbuckets 不为nil，说明正在扩容
	if c := h.oldbuckets; c != nil {
		//如果是不同size的扩容，详细查看后续的扩容部分
		if !h.sameSizeGrow() {
			// 说明过去只有一半的bucket; m/2
			m >>= 1
		}
		//找到key在旧的map中的位置
		oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
		//如果旧的bucket没有搬到新的bucket，在旧的bucket找
		if !evacuated(oldb) {
			b = oldb
		}
	}
	top := tophash(hash)
	//查找循环，和mapassign类似，不再详细说明
bucketloop:
	for ; b != nil; b = b.overflow(t) {
		//遍历8个槽位
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top {
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			//key相等，则返回
			if t.key.equal(key, k) {
				e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				if t.indirectelem() {
					e = *((*unsafe.Pointer)(e))
				}
				return e
			}
		}
	}
	return unsafe.Pointer(&zeroVal[0])
}
```

## 哈希冲突

在阅读过增删改查的代码后，基本上我们也知道了，go map 的哈希冲突是用链表法来解决的：

- 赋值时，如果发生冲突，从前往后找到第一个空位放置，如果没有，则在 bucket 的末尾创建一个 `overflow bucket`
- 查找时，如果发生冲突，则继续往后找，直到 key 相等或者 `overflow==nil`

当然，为了避免故意构造 key 制造哈希冲突攻击，go 的 map 初始化的时候是有随机的 hash seed 的:

```go
h.hash0 = fastrand()
```

## map 的扩容

在前文的代码阅读中，我们发现几乎都有判断 map 扩容相关的逻辑，显然，map 在元素增长到一定程度的时候，就会扩容。
那么，在什么情况下会发生扩容呢？

### 扩容的时机

map 的扩容的触发是在 `mapassign`：

```go
	// 如果过已经达到了负载因子(count/2^B>6.5)或者overflow的bucket太多了
// 并且不在扩容中，则开始扩容
if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
	hashGrow(t, h)
	goto again // Growing the table invalidates everything, so try again
}
```

其中 `overLoadFactor` 判断是否超过负载因子

```go
func overLoadFactor(count int, B uint8) bool {
	return count > bucketCnt && uintptr(count) > loadFactorNum*(bucketShift(B)/loadFactorDen)
}
```

`tooManyOverflowBuckets` 判断`overflow bucket`是否超过阈值

```go

func tooManyOverflowBuckets(noverflow uint16, B uint8) bool {
	if B > 15 {
		B = 15
	}
	return noverflow >= uint16(1)<<(B&15)
}

```

由此，我们可以得知，map 扩容的时机有以下两种情况：

- 当 map **达到了负载因子的临界点(h.count/2^B > 6.5)**,这说明 map 几乎要满了
  > 关于负载因子为什么是 6.5，这是经过了大量实验的出来的结果
- 当 map 的 **`overflow bucket`过多**：
  - B < 15,即 bucket 的数量 < 2^15 时，`overflow bucket`的数量>=bucket 的数量
  - B >= 15,即 bucket 的数量 >=2^15 时，overflow bucket`的数量>=2^5
    > 这种情况一般发生于一边写入一边删除，导致 bucket 出现大量的空槽位

如果满足扩容的条件，则会调用`hashGrow` 函数:

```go
func hashGrow(t *maptype, h *hmap) {
	// 如果超过负载因子,则将bucket的数量扩大一倍
	// 否则，则说明是overflow bucket 过多，不需要扩大bucket的数量
	bigger := uint8(1)
	if !overLoadFactor(h.count+1, h.B) {
		bigger = 0
		h.flags |= sameSizeGrow
	}
	oldbuckets := h.buckets
	//申请新的
	newbuckets, nextOverflow := makeBucketArray(t, h.B+bigger, nil)

	flags := h.flags &^ (iterator | oldIterator)
	if h.flags&iterator != 0 {
		flags |= oldIterator
	}
	// 修改h.map的结构，提交变更
	h.B += bigger
	h.flags = flags
	h.oldbuckets = oldbuckets
	h.buckets = newbuckets
	// 搬迁进度为0
	h.nevacuate = 0
	h.noverflow = 0

	if h.extra != nil && h.extra.overflow != nil {
		// 将之前的overflow 赋值给old overflow bucket
		if h.extra.oldoverflow != nil {
			throw("oldoverflow is not nil")
		}
		h.extra.oldoverflow = h.extra.overflow
		h.extra.overflow = nil
	}

	// 空的overflow bucket
	if nextOverflow != nil {
		if h.extra == nil {
			h.extra = new(mapextra)
		}
		h.extra.nextOverflow = nextOverflow
	}
	//实际上map的扩容是在growWrok()和evacuate()中增量进行的

}
```

### 如何扩容

我们现在知道了 map 是何时触发扩容的，那么，map 是如何扩容的呢？

map 扩容主要的函数是`growWork`和`evacuate`，growWork 会在
`mapassign`，`mapdelete` 时调用

```go
func growWork(t *maptype, h *hmap, bucket uintptr) {
	// 确保我们要搬运的oldbucket 是我们将要使用的bucket
	evacuate(t, h, bucket&h.oldbucketmask())

	// 如果还是在扩容的状态，我们再搬运一个bucket
	if h.growing() {
		evacuate(t, h, h.nevacuate)
	}
}
```

```go
func evacuate(t *maptype, h *hmap, oldbucket uintptr) {
	//定位oldbuckets
	b := (*bmap)(add(h.oldbuckets, oldbucket*uintptr(t.bucketsize)))
	newbit := h.noldbuckets()
	if !evacuated(b) {
		// TODO: reuse overflow buckets instead of using new ones, if there
		// is no iterator using the old buckets.  (If !oldIterator.)

		// x表示新bucket的前半部分
		// y表示新bucket的后半部分
		// 为什么要分成两部分？
		var xy [2]evacDst
		x := &xy[0]
		x.b = (*bmap)(add(h.buckets, oldbucket*uintptr(t.bucketsize)))
		x.k = add(unsafe.Pointer(x.b), dataOffset)
		x.e = add(x.k, bucketCnt*uintptr(t.keysize))

		if !h.sameSizeGrow() {
			// 如果B扩大了，那么只计算y,否则GC将看到破坏的指针
			y := &xy[1]
			y.b = (*bmap)(add(h.buckets, (oldbucket+newbit)*uintptr(t.bucketsize)))
			y.k = add(unsafe.Pointer(y.b), dataOffset)
			y.e = add(y.k, bucketCnt*uintptr(t.keysize))
		}

		// 处理bucket的overflow
		for ; b != nil; b = b.overflow(t) {
			k := add(unsafe.Pointer(b), dataOffset)
			e := add(k, bucketCnt*uintptr(t.keysize))
			for i := 0; i < bucketCnt; i, k, e = i+1, add(k, uintptr(t.keysize)), add(e, uintptr(t.elemsize)) {
				top := b.tophash[i]
				//已经搬完了
				if isEmpty(top) {
					b.tophash[i] = evacuatedEmpty
					continue
				}
				if top < minTopHash {
					throw("bad map state")
				}
				k2 := k
				if t.indirectkey() {
					k2 = *((*unsafe.Pointer)(k2))
				}
				var useY uint8
				if !h.sameSizeGrow() {
					//计算hash,从而确认是搬到x部分还是y部分
					hash := t.hasher(k2, uintptr(h.hash0))
					if h.flags&iterator != 0 && !t.reflexivekey() && !t.key.equal(k2, k2) {
						// If key != key (NaNs), then the hash could be (and probably
						// will be) entirely different from the old hash. Moreover,
						// it isn't reproducible. Reproducibility is required in the
						// presence of iterators, as our evacuation decision must
						// match whatever decision the iterator made.
						// Fortunately, we have the freedom to send these keys either
						// way. Also, tophash is meaningless for these kinds of keys.
						// We let the low bit of tophash drive the evacuation decision.
						// We recompute a new random tophash for the next level so
						// these keys will get evenly distributed across all buckets
						// after multiple grows.
						//这是一段很特殊的逻辑
						//引用自曹大的文章，比如两个key是 math.NaN()的时候，
						// 可能会不相等，但是是不可复现的.
						// 在迭代的时候可复现是必须的,因为搬运的决定和迭代器的决定要一致
						// 幸运的是，我们可以对这种key随机分配，而且tophash也没有意义
						// 使用随机的tophash是的这些key最终将平均分配到各个bucket

						useY = top & 1 //50%的概率去上半区
						top = tophash(hash)
					} else {
						// newbit是oldbucket的数量
						// 扩容后hash会比原来多一位
						// 两者做与运算后,很容易知道是上半区还是下半区
						if hash&newbit != 0 {
							useY = 1
						}
					}
				}

				if evacuatedX+1 != evacuatedY || evacuatedX^1 != evacuatedY {
					throw("bad evacuatedN")
				}

				b.tophash[i] = evacuatedX + useY // evacuatedX + 1 == evacuatedY
				dst := &xy[useY]                 // evacuation destination

				if dst.i == bucketCnt {
					dst.b = h.newoverflow(t, dst.b)
					dst.i = 0
					dst.k = add(unsafe.Pointer(dst.b), dataOffset)
					dst.e = add(dst.k, bucketCnt*uintptr(t.keysize))
				}
				dst.b.tophash[dst.i&(bucketCnt-1)] = top // 一个小优化，避免边界检查
				if t.indirectkey() {
					*(*unsafe.Pointer)(dst.k) = k2 // 拷贝指针
				} else {
					typedmemmove(t.key, dst.k, k) // 拷贝值
				}
				if t.indirectelem() {
					*(*unsafe.Pointer)(dst.e) = *(*unsafe.Pointer)(e)
				} else {
					typedmemmove(t.elem, dst.e, e)
				}
				dst.i++
				// These updates might push these pointers past the end of the
				// key or elem arrays.  That's ok, as we have the overflow pointer
				// at the end of the bucket to protect against pointing past the
				// end of the bucket.
				dst.k = add(dst.k, uintptr(t.keysize))
				dst.e = add(dst.e, uintptr(t.elemsize))
			}
		}
		// 为GC，不在指向overflow和清空key/elem
		if h.flags&oldIterator == 0 && t.bucket.ptrdata != 0 {
			b := add(h.oldbuckets, oldbucket*uintptr(t.bucketsize))

			//保护 b.tophash,因为迁移状态保存在那里
			ptr := add(b, dataOffset)
			n := uintptr(t.bucketsize) - dataOffset
			memclrHasPointers(ptr, n)
		}
	}


	if oldbucket == h.nevacuate {
		advanceEvacuationMark(h, t, newbit)
	}
}
```

```go
func advanceEvacuationMark(h *hmap, t *maptype, newbit uintptr) {
	h.nevacuate++

	// magic number...
	stop := h.nevacuate + 1024
	if stop > newbit {
		stop = newbit
	}
	for h.nevacuate != stop && bucketEvacuated(t, h, h.nevacuate) {
		h.nevacuate++
	}
	if h.nevacuate == newbit { // newbit == # of oldbuckets
		// 扩容结束，释放老的bucket array
		h.oldbuckets = nil
		// Can discard old overflow buckets as well.
		// If they are still referenced by an iterator,
		// then the iterator holds a pointers to the slice.
		// 同时也可以丢弃老的overflow bucket
		// 如果被迭代器引用，迭代器会持有指向overflow bucket的指针
		if h.extra != nil {
			h.extra.oldoverflow = nil
		}
		h.flags &^= sameSizeGrow
	}
}
```

## map 的一些常见问题

- map 的 key 支持哪些类型？

  - 从语法层面上，只要是能够比较的类型，都可以作为 map 的 key
  - 从逻辑层面:
    - float 类型因为精度的问题(浮点数是以 IEEE754 标准存储的)，不建议作为 key，否则可能会有诡异的问题
    - math.NaN()，在阅读扩容 相关的代码其实已经有提到，具体可以查看`runtime/alg.go`中的`f64hash`针对 NaN 的处理

- map 是并发(goroutine)安全的吗?
  - 不是，上文中很多代码都有并发检测，并发读写会 panic
  - 如果要求并发安全，使用 go 标准库中的`sync.Map`或者自己封装一个带锁的 map

## 参考&推荐阅读

[Go 程序是怎样跑起来的](https://juejin.im/post/5d1c087af265da1bb5651356)

[golang-notes](https://github.com/cch123/golang-notes)

[码农桃花源](https://qcrao91.gitbook.io/)

[Cryptographic hash function](https://en.wikipedia.org/wiki/Cryptographic_hash_function)

[Cryptanalysis of AES-Based Hash Functions](https://online.tugraz.at/tug_online/voe_main2.getvolltext?pCurrPk=58178)

[Go ARM64 Map 优化小记](https://mzh.io/golang-aeshash-arm64/)
