---
title: "[源码阅读]Go 1.14 Map"
date: 2020-04-21T20:53:00+08:00
tags: ["golang","map","源码"]
categories: ["golang","源码"]
draft: true
---


## 前言

这是我第一次写源码分析的文章，在写这篇文章之前，我阅读过一些写的很好Go源码分析的文章，比如本文参考的饶大的[码农桃花源](https://qcrao91.gitbook.io/go/map)系列。但是，而随之时间的推移，Go版本迭代，源码还是会有一些细微的变动；再者，我觉得看别人的文章，不如自己写一篇理解地深刻。 本文将从一个示例程序启动开始，尽可能探索map相关的源码，并附上相关源码的出处。珠玉在前，本文难免有不足，望见谅。

由于大部分的 Go 程序跑在 linux 下，因此平台相关的代码也以 `linux/amd64` 为准
这是我在阅读源码时的 go 版本
```
% go version
go version go1.14 linux/amd64
```



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
这个函数在程序启动时会被调用，根据源码，可以很清晰的看到，当 cpu 架构是 `x86` 或者 `amd64` 的时候，且 cpu 支持 `AESENC` 等指令，或者 `arm64` 架构下支持`AESENC`指令时，就使用 AES Hash作为哈希算法，如果不是支持，将会进入`getRandomData`函数，这个函数最终是使用的`memhash`,
调用路径是`alginit`->`getRandomData`->`extendRandom`->`memhash`。

我在看别人文章时，一直有一个疑问，AES不是对称加密算法吗？怎么又变成了哈希算法？事实上，这二者是不同的东西，我们常见的 `MD5`,`SHA-1`,`SHA-256` 等，都属于加密型哈希，是不可逆的；而非加密型哈希，常见的有`CRC32`,一般用于校验消息的完整性。AES哈希只是因为用了`AES`相关的CPU指令，实际上和对称加密的那个`AES`是不一样的，关于`AES Hash`的资料少之又少，本文参考中附有两篇相关论文。



## 创建Map
我们创建一个map，一般是通过`make(map[k]v, hint)`函数创建，而这个函数在编译期，会变成`func makemap(t *maptype, hint int, h *hmap) *hmap`， 位于`runtime/map.go:303`,这里可以看到，当我们创建一个map的时候，实际上是创建了一个 `×hmap`指针，hmap才是map真正的底层结构。

这里我们先看看`hmap`的结构
```golang
type hmap struct {
	
	count     int // map的大小，调用len()函数是返回的就是count的值
	flags     uint8
	B         uint8  // bucket 数量的2的对数 最大数量为 负载因子×2^B  
    noverflow uint16 // overflow的近似数或者
	hash0     uint32 // hash seed

	buckets    unsafe.Pointer // bucket 数组，如果元素个数为0，则为nil
	oldbuckets unsafe.Pointer // 只有在扩容的时候不是nil,大小是buckets的1/2
    nevacuate  uintptr        // 指示扩容进度，小于这地址的bucket是已经迁移的 
	extra *mapextra // optional fields
}
```
其中`bucket`的结构如下，包含一个8个长度的数组
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
	// 在内存中，key和elem是 key/elem/key/elem/...排列的
	// 因为这样可以消除padding
    keys     [8]keytype
    elems    [8]elemtype
    overflow uintptr
}
```


## 哈希冲突

## map的扩容



## map的key支持哪些类型？
## 参考&推荐阅读

[Go 程序是怎样跑起来的](https://juejin.im/post/5d1c087af265da1bb5651356)

[码农桃花源](https://qcrao91.gitbook.io/)

[](https://en.wikipedia.org/wiki/Cryptographic_hash_function)
[Cryptanalysis of AES-Based Hash Functions](https://online.tugraz.at/tug_online/voe_main2.getvolltext?pCurrPk=58178)

