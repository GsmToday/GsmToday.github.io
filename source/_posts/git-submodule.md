---
title: Git子模块实践
toc: false
author: GSM
thumbnail: /images/daishu.jpeg
date: 2017-11-28 21:33:29
tags: Git
---

## 应用背景
Git 子模块的使用场景是多个项目都使用了一个公共的项目，为了节省开发成本并且减少出错几率，我们想要实现：每个使用公共项目的外部项目如果更改了这个公共项目，这些更新都可以同步到其他使用了这个公共项目的项目中。Git提供了「子模块」这个工具。

<!-- more -->

举个例子，我们的浏览项目是组建化活动装修中的一个lua项目，具体业务涉及到某A国的店铺／活动浏览业务，以及某B国活动／店铺浏览业务，以后还会有更多扩展业务。某A国的店铺／活动浏览业务（我们这里称deploy_mall和deploy_act）部署工具支持lua脚本的直接运行，因此某A国项目代码库只需要包括：
1. lua业务核心代码 — esale文件夹
2. 部署脚本（nginx.conf相关）

但是某B国项目（我们这里称为sale-web)部署工具不支持lua脚本的运行，因此需要自己搭建一个web shell(tomcat)来启动，我们只能把lua代码放在 webapp/WEB-INFO/esale 文件夹下。因此代码库包括：
1. web.xml 的src目录
2. 部署脚本（nginx.conf相关）
3.  webapp/WEB-INFO/esale文件夹的lua核心代码

可见，sale-web和esale两个工程虽然代码结构不同，但是核心都是一个esale文件夹下的lua浏览工程。因此，我们需要实现任何一个项目，例如sale-web对lua代码做了更新，deploy_mall工程或者deploy_sale可以同步拉到更新，从而“实现维护一套代码，组建化支持多个项目”这个目的。

![][0]

## 子模块原理
一个Git子模块就是一个标准的Git仓库。不同的是，这个Git仓库被包含在另外一个或者多个外部项目的Git仓库中（有点内部类的意思）。子模块和普通的Git仓库没什么区别，可以对他进行`pull`,`commit`,`fetch`,`push`等。 那Git 是如何保持多个外部项目仓库和他的Git子模块实现同步更新的呢？答案在于当我们在外部仓库中创建了一个Git子模块，会在外部仓库中同时创建一个 `.gitmodule`， `.gitmodule ` 里面记录了对子模块的git 引用路径和子模块代码库的地址，即标识了哪个目录是子模块，这个子模块的代码地址。

![][1]

事实上，外部项目并没有保存子模块的代码，只是保存了一个指向子模块的引用。所以如果我们git clone一个外部项目时候，会发现clone下来外部项目的子项目文件夹是空的。
(a) 可以通过将 “--recurse-submodules” 参数加在 “git clone” 上，从而让 Git 知道，当克隆完成的时候要去初始化所有的子模块。
(b) 如果仅仅只是简单地使用了 “git clone” 命令，并没有附带任何参数，你就需要在完成之后通过 “git submodule update --init --recursive” 命令来初始化那些子模块

## 实践

## 搭建子模块
Step 1: 创建子模块的git 代码库。我们给这个项目起名 esale
Step 2: 分别在两个使用到 sub-esale的项目（esale和sale-web）中添加子模块：
    对于sale-web 使用“git submodule add http://你的git地址”

![][2]

会发现生成了一个esale文件夹，代表git子模块。在外部项目里会发现生成了记录子模块引用的.gitmodules文件。
![][4]
![][5]


###  使用子模块的某个分支
和一个普通的Git仓库不同的是，子模块永远指向一个特定的提交，而不是分支。这是因为一个分支的内容可以在任何时间通过新的提交来改变。所以指向一个特定的提交版本就能始终保证代码的正确。所以通常外部项目具体使用子项目哪次提交来运行，我们称之为「签出一个版本」。

如果我们想让外部项目使用子模块的一个特定分支：

Step 0: 进入到子模块查看 git log —oneline —decorate 查看历史提交和分支记录

![][7]

Step 1: git checkout 特定分支（也可以git checkout versionnum）

Step 2: 在外部项目中查看 git submodule status 子模块当前哪个版本被签出了。正是我们checkout到新分支的版本

![][8]

Step 3: 为了让这个改动生效，需要将它commit到库里

![][9]

### 克隆一个带有子模块的项目

克隆一个带有子模块的项目。将得到了包含子项目的目录，但里面没有文件：esale 目录虽然存在，但是是空的。需要运行两个命令：

```
git submodule init 初始化你的本地配置文件
git submodule update 从那个项目拉取所有数据并检出你上层项目里所列的合适的提交。
```

## 对子模块做更新

### 修改esale子模块

当修改esale子模块内容并提交后，在sale-web外部工程进入esale目录拉取代码。可以同步收到更新。
git pull orgin master


切换到，一个没有submodule的分支时，会首先需要把submodule目录移动走。当我们切换回来时，由于lua目录被移走需要手动移回来或者执行上述命令重新初始化一次。最后执行一次同步。

参考
https://www.git-tower.com/learn/git/ebook/cn/command-line/advanced-topics/submodules

https://git-scm.com/book/zh/v2/Git-%E5%B7%A5%E5%85%B7-%E5%AD%90%E6%A8%A1%E5%9D%97

[0]: archi.png
[1]: 1.png
[2]: 2.png
[4]: 4.png
[5]: 5.png
[7]: 7.png
[8]: 8.png
[9]: 9.png