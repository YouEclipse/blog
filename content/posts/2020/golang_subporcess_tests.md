---
title: "理解 Golang 子进程测试"
date: 2020-01-11T20:32:51+08:00
draft: false
---

最近在写 logger 的单元测试的时候遇到了一个问题,如果直接执行 `logger.Fatal`,由于这个函数底层调用了 `os.Exit(1)` ,进程会直接终止,testing 包会认为 test failed.虽然这是个简单的函数，而且几乎用不上，但是迫于强迫症，必须给他安排一个单元测试。
后来意外找到了Andrew Gerrand（Golang的开发者之一） 在 Google I/O 2014 上一篇关于测试技巧的slide（见[附录](#jump)）,里面有讲到 subporcess tests, 也就是子进程测试,内容如下：

>> Sometimes you need to test the behavior of a process, not just a function.

```golang
   func Crasher() {
        fmt.Println("Going down in flames!")
        os.Exit(1)
    }
```
>> To test this code, we invoke the test binary itself as a subprocess:

```golang
func TestCrasher(t *testing.T) {
    if os.Getenv("BE_CRASHER") == "1" {
        Crasher()
        return
    }
    cmd := exec.Command(os.Args[0], "-test.run=TestCrasher")
    cmd.Env = append(os.Environ(), "BE_CRASHER=1")
    err := cmd.Run()
    if e, ok := err.(*exec.ExitError); ok && !e.Success() {
        return
    }
    t.Fatalf("process ran with err %v, want exit status 1", err)
}
```
这里讲到如果我们要测试进程的行为，而不仅仅是函数，那么我们可以通过单元测试的二进制文件创建一个子进程来测试。所以回过头来，从测试的角度出发，我们需要测试`Fatal`函数的这两个行为：
- 打印日志文本
- 有错误地终止进程

所以我们单元测试就需要覆盖函数的这两个行为，Andrew Gerrand 讲的子进程测试的技巧，正好适用这种情况。所以可以参考这个例子，给`Fatal`写一个单元测试

假设我们的Fatal函数是基于标准库的log包的封装
```golang
    package logger

    func Fatal(v ...interface{}){
        log.Fatal(v...)
    }
```
这里我们可以先看下标准库log包的实现(事实上 zap/logrus 等log包的`Fatal`函数也是类似的，最终都调用了`os.Exit(1)`) 
```golang
func Fatal(v ...interface{}) {
	std.Output(2, fmt.Sprint(v...))  //输出到标准输出/标准错误输出
	os.Exit(1) // 有错误地退出进程
}
```
先按正常的思路写一个单元测试
```golang
func TestFatal(t *testing.T) {
    Fatal("fatal log")
}
```
执行单元测试的结果如下，如我之前所说，结果是FAIL
```
go test -v
=== RUN   TestFatal
2020/01/11 11:39:24 fatal log
exit status 1
FAIL    github.com/YouEclipse/mytest/log        0.001
```

我们照猫画虎，尝试写一个子进程测试,这里我把标准输出和标准错误输出都打印出来了
```golang
func TestFatal(t *testing.T) {
	if os.Getenv("SUB_PROCESS") == "1" {
		Fatal("fatal log")
		return
	}
	var outb, errb bytes.Buffer
	cmd := exec.Command(os.Args[0], "-test.run=TestFatal")
	cmd.Env = append(os.Environ(), "SUB_PROCESS=1")
	cmd.Stdout = &outb
	cmd.Stderr = &errb
	err := cmd.Run()
	if e, ok := err.(*exec.ExitError); ok && !e.Success() {
		fmt.Print(cmd.Stderr)
		fmt.Print(cmd.Stdout)
		return
	}
	t.Fatalf("process ran with err %v, want exit status 1", err)
}

```
执行单元测试,结果果然是成功的，达到了我们的预期
```
go test -v
=== RUN   TestFatal
2020/01/11 11:40:38 fatal log
--- PASS: TestFatal (0.00s)
PASS
ok      github.com/YouEclipse/mytest/log        0.002s
```


当然，我们不仅要知其然，更要知其所以然。我们分析一下子进程测试代码为什么是这样写

- 通过`os.Getenv`获取环境变量，这里值为空，所以Fatal并不会执行

- 定义了`outb`,`errb`，这里是为了后续捕捉标准输出和标准错误输出

- 调用`exec.Command` 根据传入的参数构造一个Cmd的结构体

exec 是标准库中专门用于执行命令的的包，这里不做太多赘述
我们可以看到，exec.Cmmand 第一个参数是要执行的命令或者二进制文件的名字，第二个参数是不定参数，是我们需要执行的命令的参数  
这里我们第一个参数传入了`os.Args[0]`,  `os.Args[0]`是程序启动时的程序的二进制文件的路径,第二个参数是执行二进制文件时的参数。至于为什么是`os.Args[0]`而不是`os.Args[1]`或者`os.Args[2]`呢,我们执行一下`go test -n`,你会看到输出了一堆东西（省略了大部分无关内容）
```
mkdir -p $WORK/b001/

#
# internal/cpu
#
... 
/usr/local/go/pkg/tool/linux_amd64/compile -o ./_pkg_.a -trimpath "$WORK/b001=>" -p main -complete -buildid 5WmoKx2_LnkcztVfW1Bj/5WmoKx2_LnkcztVfW1Bj -dwarf=false -goversion go1.13.5 -D "" -importcfg ./importcfg -pack -c=4 ./_testmain.go
...

/usr/local/go/pkg/tool/linux_amd64/link -o $WORK/b001/log.test -importcfg $WORK/b001/importcfg.link -s -w -buildmode=exe -buildid=o8I_q2gkkk-Xda8yeh2G/5WmoKx2_LnkcztVfW1Bj/5WmoKx2_LnkcztVfW1Bj/o8I_q2gkkk-Xda8yeh2G -extld=gcc $WORK/b001/_pkg_.a
...
cd /home/yoyo/go/src/github.com/YouEclipse/mytest/log
TERM='dumb' /usr/local/go/pkg/tool/linux_amd64/vet -atomic -bool -buildtags -errorsas -nilfunc -printf $WORK/b052/vet.cfg
$WORK/b001/log.test -test.timeout=10m0s
```
从输出的内容我们可以知道`go test`最终是将源码文件编译链接成二进制文件（当然还有govet静态检查）执行的。实际上`go test`和`go run`最终调用的是同一个函数，这篇文章对此也不做过多讨论，具体可以查看源码中`cmd/go/internal/test/test.go`和`cmd/go/internal/work/build.go`这两个文件的内容。

而`-n` 参数，可以打印`go test`或者`go run` 执行过程中用到的所有命令，所以我们在输出的最后一行，执行了最终的二进制文件并且带上了`-test.timeout=10m0s`默认超时的flag。而os.Args是os包的一个常量，在进程启动时，就会把执行的命令和flag写入
```golang
// Args hold the command-line arguments, starting with the program name.
var Args []string
```
所以 `os.Args[0]`自然获取的就是编译后的二进制文件的完整文件名。

第二个参数`-test.run=TestFatal` 是执行二进制文件的flag，`test.run`flag 指定的test的函数名。
当我们执行`go test -run TestFatal`时，实际上最终就是执行成`$WORK/b001/log.test -run=TestFatal`
其他flag可以执行`go help testflag`查看，或者参考 `cmd/go/internal/test/testflag.go`文件中的`testFlagDefn`传入，具体定义和说明都在源码中。
- cmd.Env 设置子进程运行的环境变量
os.Environ() 获取当前环境变量的拷贝，我们添加一个`SUB_PROCESS`环境变量用户判断是否是子进程。
- cmd.Stdout = &outb 
- cmd.Stderr = &errb
捕获子进程运行时的标注输出和标准错误，因为我们需要测试是否输出
-  cmd.Run()
启动子进程，等待返回结果 如果退出，可能会返回`exec.ExitError`,可以拿到退出的statusCode，而我们的目的就是测试进程是否退出
- 在子进程中，此时环境变量`SUB_PROCESS`的值为`1`，这时候会执行`Fatal`函数，主进程收到exit code，打印子进程的输出


至此，这段测试代码的原理我们也清楚了。

但是，美中不足的是，在执行`go test -cover`进行测试覆盖率统计的时候,通过子进程运行的单元测试的函数，并不会被统计上。

## <span id="jump">附录</span>

1. [Testing Techniques](https://talks.golang.org/2014/testing.slide#23) - Andrew Gerrand 
