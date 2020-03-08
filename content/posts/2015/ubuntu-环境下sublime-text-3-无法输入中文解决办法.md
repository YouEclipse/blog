---
title: "ubuntu 环境下sublime text 3 无法输入中文解决办法"
date: 2015-05-27T16:58:03+08:00
tags: ["linux","ubuntu"]
categories: ["linux"]
draft: false
---


系统：ubuntu 14.04
输入法： 搜狗拼音 for Linux

<!--more-->
---
-  #####新建一个文件sublime_imfix.c
```
vim sublime_imfix.c
```


将如下代码复制到sublime_imfix.c中

```
#include <gtk/gtkimcontext.h>

void gtk_im_context_set_client_window (GtkIMContext *context,

         GdkWindow    *window)

{

 GtkIMContextClass *klass;

 g_return_if_fail (GTK_IS_IM_CONTEXT (context));

 klass = GTK_IM_CONTEXT_GET_CLASS (context);

 if (klass->set_client_window)

   klass->set_client_window (context, window);

 g_object_set_data(G_OBJECT(context),"window",window);

 if(!GDK_IS_WINDOW (window))

   return;

 int width = gdk_window_get_width(window);

 int height = gdk_window_get_height(window);

 if(width != 0 && height !=0)

   gtk_im_context_focus_in(context);

}
```

- #####安装 libgtk2.0-dev（编译时要用到）
```
sudo apt-get install libgtk2.0-dev
```

- #####将 sublime_imfix.c 编译成共享库libsublime-imfix.so
```
gcc -shared -o libsublime-imfix.so sublime_imfix.c  `pkg-config --libs --cflags gtk+-2.0` -fPIC
```
- #####将libsublime-imfix.so拷贝到sublime_text所在文件夹
```
sudo mv libsublime-imfix.so /opt/sublime_text/
```

- #####修改文件/usr/bin/subl的内容
```
sudo vim /usr/bin/subl
```
将
```
#!/bin/sh
exec /opt/sublime_text/sublime_text "$@"
```
修改为
```
#!/bin/sh
LD_PRELOAD=/opt/sublime_text/libsublime-imfix.so exec /opt/sublime_text/sublime_text "$@"
```

- #####修改文件sublime_text.desktop(也就是桌面快捷方式)
```
sudo vim /usr/share/applications/sublime_text.desktop
```
将[Desktop Entry]中的字符串
```
Exec=/opt/sublime_text/sublime_text %F
```
修改为
```
Exec=bash -c "LD_PRELOAD=/opt/sublime_text/libsublime-imfix.so exec /opt/sublime_text/sublime_text %F"
```
将[Desktop Action Window]中的字符串
```
Exec=/opt/sublime_text/sublime_text -n
```
修改为
```
Exec=bash -c "LD_PRELOAD=/opt/sublime_text/libsublime-imfix.so exec /opt/sublime_text/sublime_text -n"
```
将[Desktop Action Document]中的字符串
```
Exec=/opt/sublime_text/sublime_text --command new_file
```
修改为
```
Exec=bash -c "LD_PRELOAD=/opt/sublime_text/libsublime-imfix.so exec /opt/sublime_text/sublime_text --command new_file"
```
保存后，再次打开sublime text 3 即可输入中文
