---
title: "Istio 1.7 是如何保证sidecar的启动顺序的"
date: 2020-08-27T23:43:20+08:00
tags: ["istio", "go"]
categories: ["istio", "go"]
draft: false
featuredImagePreview: "/images/blog/sidecar-lifecycle.png"
---

## 前言

2020 年 8 月 27 日,`Istio` 发布了 1.7 版本，宣称这是一个真正产线可用的版本.其中针对`Traffic Management`增了一个配置`values.global.proxy.holdApplicationUntilProxyStarts`,可以支持让 sidecar 启动后才启动你的应用容器，这解决了一个 `Istio` 一直存在的一个问题：

<!--more-->

{{< image src="/images/blog/sidecar-lifecycle-1.gif" caption="容器生命周期(图源自 https://banzaicloud.com)" >}}

sidecar 容器 和应用容器的启动顺序是不确定的，如果应用容器先启动了，sidecar 还未完成启动，这时候应用容器往外发送流量，流量仍然会被拦截，发往未启动的 envoy，就会导致请求失败。

## 现状

我在公司落地`Istio`时就遇到这个问题, 我们使用的是 1.6 版本,具体的场景就是微服务启动初始化时要调接口拉取配置中心的配置，但是由于 sidecar 未启动，拉取配置失败，服务则会终止启动,导致容器只能等待 sidecar 起来后被 `Kubernetes` 的`restartPolicy` 机制自动拉起.为了解决这个问题，目前业界有比较普遍的作法：

- 一种是应用容器延迟几秒启动
- 另一种则是在应用容器的启动脚本调用 envoy 健康检查接口，确保 envoy 启动了再启动应用，这样就避免了应用启动时的访问异常.

由于我们公司目前的微服务基本都是 Go 编写的,而服务初始化拉取配置的逻辑都使用了基础库中封装的逻辑,为了方便,我们直接在基础库拉取配置的代码之前加了`WaitSidecar()`这么一段逻辑,就是每隔一秒调用`envoy`的健康检查接口`/healthz/ready`,直到返回 200 或者超时(理论上此时 envoy 已经正常启动),则继续后续的服务初始化逻辑.

```go
...
// WaitSidecar waits until sidecar is health
func WaitSidecar() {
    //判断是否运行在k8s集群中
	if len(os.Getenv("KUBERNETES_SERVICE_HOST")) > 0 && len(os.Getenv("NO_SIDECAR")) <= 0 {
		tic := time.NewTicker(1 * time.Second)
		defer tic.Stop()
		after := time.After(30 * time.Second)
		for {
			select {
			case <-tic.C:
                logger.Infof("[main] sidecar health checking")
                //sidercar健康检查
				if sidecarHealthCheck() {
					return
				}
			case <-after:
				logger.Warn("[main] sidecar health check timeout after 30 seconds")
				return
			}
		}
	}
	return
}


...

func sidecarHealthCheck() bool {
	cli := http.Client{
		Timeout: 1 * time.Second,
	}
    // envoy健康检查接口
	resp, err := cli.Get("http://127.0.0.1:15021/healthz/ready")
	if err != nil {
		logger.Warn("[main] sidecarHealthCheck failed,err", err)
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return true
	}
	return false
}

```

加上这段逻辑,基本上解决了我们服务部署时启动异常的问题.这么做,虽然达到了目的,但是所有的服务都需要重新打包部署,一定程度上也违背了 service mesh 的理念，实在是不够优雅,但是有没有更好的实现方式呢?

## Istio 1.7 的实现

### 容器的启动顺序

在出现问个问题的时候，我们都会下意识的认为原因是因为同一个 pod 中的容器都是同时开始启动的,应用容器启动的时间比 sidecar 容器启动时间短导致的。但是根据`kubelet`的源码,你会发现容器确实是按顺序启动的:

> [`kubelet/kuberuntime/kuberuntime_manager.go`](https://github.com/kubernetes/kubernetes/blob/v1.18.6/pkg/kubelet/kuberuntime/kuberuntime_manager.go#L830-L833)

```go
    // Step 7: start containers in podContainerChanges.ContainersToStart.
	for _, idx := range podContainerChanges.ContainersToStart {
		start("container", containerStartSpec(&pod.Spec.Containers[idx]))
	}
```

那么如果我们调整`spec.containers`,确保 sidecar 容器是第一个个启动的，是不是就解决问题了呢？ 实际上，问题依然存在。假设我们的容器的镜像都已经在本地了,那么启动完 sidecar 容器后(可能并未正常工作)，启动应用容器花的时间几乎可以忽略不计了,也就是说,容器的启动时间点几乎是同时的.在这种情况下,调整容器的启动顺序其实并不能改变什么.所以,我们只能通过其他方式来解决这个问题.

### 容器生命周期回调

类似于一些编程语言框架,kubernetes 也为容器提供了生命周期回调,这使得我们可以在相对应的容器生命周期执行一些代码。
kubernetes 提供了两种生命周期回调，并可以为他配置回调处理程序:

- `PostStart`:在创建容器后立即执行
- `PreStop`：在容器终止之前执行

根据官方文档的说明:

> Hook handler calls are synchronous within the context of the Pod containing the Container. This means that for a PostStart hook, the Container ENTRYPOINT and hook fire asynchronously. However, if the hook takes too long to run or hangs, the Container cannot reach a running state.

这意味着，`PostStart`回调和容器的`ENTRYPOINT`是异步执行的，只有两者执行都成功了，容器才会达到 running 的状态。

所以，我们完全可以在 sidecar 容器的生命周期回调的`PostStart` 上做手脚， 让他执行一段脚本或程序去对`envoy`做健康检查，这样就能阻止第二个容器的启动:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-starts-first
spec:
  containers:
    - name: sidecar
      image: my-sidecar
      lifecycle:
        postStart:
          exec:
            command:
              - /bin/wait-until-ready.sh
    - name: application
      image: my-application
```

{{< image src="/images/blog/sidecar-lifecycle.png" caption="sidecar postStart(图源自文章 Delaying application start until sidecar is ready)" >}}

实际上,为了解决 sidecar 启动顺序的问题,`Kubernetes`官方在 1.18 之后特别引入了`sidecar container lifecycle`的概念,也就是说,通过对 k8s 配置对应的 lifecycle，就能确保 sidecar container 在应用容器启动之前启动。

{{< image src="/images/blog/sidecar-lifecycle-2.gif" caption="kubernetes1.18之后容器生命周期(图源自 https://banzaicloud.com)" >}}

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bookings-v1-b54bc7c9c-v42f6
  labels:
    app: demoapp
spec:
  containers:
  - name: bookings
    image: banzaicloud/allspark:0.1.1
    ...
  - name: istio-proxy
    image: docker.io/istio/proxyv2:1.4.3
    lifecycle:
      type: Sidecar
```

但是，升级 `Kubernetes`的版本是有一定风险的，而且当时 istio 官方也并未支持这个 feature，所以，这个方式目前并不行得通。

### 实现源码简析

在 Istio 发布 1.7 的时候，我对于这个 feature 的实现非常感兴趣，因为 Istio 1.7 针对`values.global.proxy.holdApplicationUntilProxyStarts`这个 feature，并没有要求 `Kubernetes`的版本，显然不是基于 1.18 的`sidecar container lifecycle`实现，所以，就去看了一下官方实现的源码,对应的 PR 可以参考附录。这是相关实现的核心逻辑:

> [`istio/pilot/cmd/pilot-agent/wait.go`](https://github.com/luksa/istio/blob/78f70b07ff98854f54dd79f3a96cf854323f6dab/pilot/cmd/pilot-agent/wait.go)

```go
var (
	timeoutSeconds       int
	requestTimeoutMillis int
	periodMillis         int
	url                  string

	waitCmd = &cobra.Command{
		Use:   "wait",
		Short: "Waits until the Envoy proxy is ready",
		RunE: func(c *cobra.Command, args []string) error {
			client := &http.Client{
				Timeout: time.Duration(requestTimeoutMillis) * time.Millisecond,
			}
			log.Infof("Waiting for Envoy proxy to be ready (timeout: %d seconds)...", timeoutSeconds)

			var err error
			timeoutAt := time.Now().Add(time.Duration(timeoutSeconds) * time.Second)
			for time.Now().Before(timeoutAt) {
				err = checkIfReady(client, url)
				if err == nil {
					log.Infof("Envoy is ready!")
					return nil
				}
				log.Debugf("Not ready yet: %v", err)
				time.Sleep(time.Duration(periodMillis) * time.Millisecond)
			}
			return fmt.Errorf("timeout waiting for Envoy proxy to become ready. Last error: %v", err)
		},
	}
)

func checkIfReady(client *http.Client, url string) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	_, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP status code %v", resp.StatusCode)
	}
	return nil
}

```

对应的实现是在`pilot-agent`，看完代码你会发现，对应的实现就是为`pilot-agent`添加的一个`wait`的命令， 逻辑和我上文中在基础库中的实现几乎是一样的逻辑，定时 `envoy`的健康检查接口直到返回 200。然后，调整容器的启动顺序将 sidecar 容器放在第一位(init container 之后):

> [`istio/pkg/kube/inject/inject.go`](https://github.com/luksa/istio/blob/78f70b07ff98854f54dd79f3a96cf854323f6dab/pkg/kube/inject/inject.go#L767)

```go
func IntoObject(sidecarTemplate string, valuesConfig string, revision string, meshconfig *meshconfig.MeshConfig, in runtime.Object) (interface{}, error) {

...
    podSpec.InitContainers = append(podSpec.InitContainers, spec.InitContainers...)

	podSpec.Containers = injectContainers(podSpec.Containers, spec)
	podSpec.Volumes = append(podSpec.Volumes, spec.Volumes...)
...

}
func injectContainers(target []corev1.Container, sic *SidecarInjectionSpec) []corev1.Container {
	containersToInject := sic.Containers
	if sic.HoldApplicationUntilProxyStarts {
		// inject sidecar at start of spec.containers
		proxyIndex := -1
		for i, c := range containersToInject {
			if c.Name == ProxyContainerName {
				proxyIndex = i
				break
			}
		}
		if proxyIndex != -1 {
			result := make([]corev1.Container, 1, len(target)+len(containersToInject))
			result[0] = containersToInject[proxyIndex]
			result = append(result, target...)
			result = append(result, containersToInject[:proxyIndex]...)
			result = append(result, containersToInject[proxyIndex+1:]...)
			return result
		}
	}
	return append(target, containersToInject...)
}
```

还有部分修改就是修改 sidecar pod 模板，添加`values.global.proxy.holdApplicationUntilProxyStarts`的判断，如果为`true`，则在对应的 lifecycle 的`postStart` 添加 `pilot-agent wait`命令.

```yaml
  {{- else if .Values.global.proxy.holdApplicationUntilProxyStarts}}
    lifecycle:
      postStart:
        exec:
          command:
          - pilot-agent
          - wait
  {{- end }}
```

## 总结

看完`Istio1.7`的代码，我们会发现，`holdApplicationUntilProxyStarts`的实现方式其实就是目前通用的解决方案之一的优化版本，而且将对`envoy`健康检查的逻辑集成到了 `pilot-agent`。这个实现虽然依然不太优雅，但是为了解决现有的一大痛点和向下兼容低版本的`Kubernetes`，这也是情理之中的。可以预见的是，在不远的将来，大部分的`kubernetes`用户的升级到 1.18 后，`Istio` 官方必然会废弃这个现实，使用更加优雅的`sidecar container lifecycle` 来实现。

## 参考 && 推荐阅读

[PR#24737](https://github.com/istio/istio/pull/24737/files#)

[Delaying application start until sidecar is ready](https://medium.com/@marko.luksa/delaying-application-start-until-sidecar-is-ready-2ec2d21a7b74)

[Istio-handbook](https://www.servicemesher.com/istio-handbook/practice/faq.html)

[Container Lifecycle Hooks](https://kubernetes.io/zh/docs/concepts/containers/container-lifecycle-hooks/)

[Sidecar container lifecycle changes in Kubernetes 1.18](https://banzaicloud.com/blog/k8s-sidecars/)

[揭开 Istio Sidecar 注入模型的神秘面纱](https://istio.io/latest/zh/blog/2019/data-plane-setup/)
