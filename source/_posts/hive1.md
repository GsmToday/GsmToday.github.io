---
title: Hive Driver源码执行流程分析
author: NX
date: 2016-05-18 20:41:22
toc: false
banner: /images/insect.jpg
tags:
  - Hive
categories: 存储
---
## 引言
接着上一篇来说[执行入口的分析][1]，`CliDriver`最终将用户指令`command`提交给了`Driver`的`run`方法（针对常用查询语句而言），在这里用户的`command`将会被编译，优化并生成MapReduce任务进行执行。所以`Driver`也是Hive的核心，他扮演了一个将用户查询和MapReduce Task转换并执行的角色，下面我们就看看Hive是如何一步一步操作的。

<!-- more -->

## 源码分析

在说`run`方法之前，由于`CliDriver`需要得到一个`Driver`类的实例，所以首先看一下`Driver`的构造方法。`Driver`有三个构造函数，主要功能也就是设置类的实例变量`HiveConf`。`SessionState`前文已经有介绍，`SessionState`返回了当前会话的一些信息，提取配置文件，初始化`Driver`实例。
```
public Driver() {
    if (SessionState.get() != null) {
      conf = SessionState.get().getConf();
    }
}
```

### run

下面就开始解析`Driver`内部对用户命令`command`的处理流程，首先是入口函数`run`. `run`函数通过调用`runInternal`方法处理用户指令，在处理完成`runInternal`之后，如果执行过程中出现出错，还附加了对错误码和错误信息的处理，此处省略。
```
public CommandProcessorResponse run(String command)
      throws CommandNeedRetryException {
    return run(command, false);
}

public CommandProcessorResponse run(String command, boolean alreadyCompiled)
        throws CommandNeedRetryException {
    CommandProcessorResponse cpr = runInternal(command, alreadyCompiled);
     ...
}
```
### runInternal
`runInternal`方法包含的主要操作有，处理`preRunHook`（具体功能可以顾名思义哦），`compile` ， `execute`， 处理`postRunHook`以及构造`CommandProcessorResponse`并返回。下面依次从代码的角度分析这几步的具体操作：
### PreRunHook
处理`preRunHook`，首先根据配置文件和指令，构造用户Hook执行的上下文`hookContext`，然后读取用户`PreRunHook`配置指定的类（字符串）， 此配置项对应于Hive配置文件当中的`“hive.exec.driver.run.hooks”`一项，利用反射机制`Class.forName`实例化`PreRunHook`类实例（`getHook`函数完成），依次执行各钩子的功能（`preDriverRun`函数完成）。
```
HiveDriverRunHookContext hookContext
    = new HiveDriverRunHookContextImpl(conf, command);
    // Get all the driver run hooks and pre-execute them.
List<HiveDriverRunHook> driverRunHooks;
try{
      driverRunHooks = getHooks(HiveConf.ConfVars.HIVE_DRIVER_RUN_HOOKS,
      HiveDriverRunHook.class);
      for (HiveDriverRunHook driverRunHook : driverRunHooks) {
          driverRunHook.preDriverRun(hookContext);
      }
}catch (Exception e) {
  errorMessage = "FAILED: Hive Internal Error: " + Utilities.getNameMessage(e);
  SQLState = ErrorMsg.findSQLState(e.getMessage());
  downstreamError = e;
  console.printError(errorMessage + "\n"
          + org.apache.hadoop.util.StringUtils.stringifyException(e));
  return createProcessorResponse(12);
}
```

### compile
编译，直接调用`complieInternal`函数编译用户指令，将指令翻译成`MapReduce`任务。这一个过程涉及的内容比较多，也很重要，后面将单独用一篇文章说明编译优化的过程。这里借用网上的一幅图，帮助对`compile`的功能有个整体的理解，参考文献: Hive实现原理.pdf。
![编译流程][2]
### execute
在运行之前还有获取锁的操作，由于新版本添加了`ACID`事务的支持，还设置了事务管理器等，目前还没详细的弄懂这块的处理逻辑和功能，先放一下，主要看下`execute`函数执行了什么操作，也就是如何根据编译结果执行任务的。

首先是从编译得到的查询计划`QueryPlan`里获取基本的查询ID，查询字串等信息，并在回话状态中把当前查询字串和查询计划插入到历史记录中。
```
String queryId = plan.getQueryId();
String queryStr = plan.getQueryStr();

if (SessionState.get() != null) {
   SessionState.get().getHiveHistory().startQuery(queryStr,
       conf.getVar(HiveConf.ConfVars.HIVEQUERYID));
   SessionState.get().getHiveHistory().logPlanProgress(plan);
}
```
与`PreRunHook`类似，在执行任务之前，检查并执行用户设定的`"hive.pre.exec.hooks"`，此处不再详述。完成这部操作之后，向控制台简单的打印一些信息之后，就开始正式执行任务了。

- **DriverContext**

创建执行上下文DriverContext，它记录的信息主要包括可执行的任务队列(Queue<Task> runnable), 正在运行的任务队列(Queue<TaskRunner> running), 当前启动的任务数curJobNo, statsTasks（Map<String, StatsTask>, what used for?）以及语义分析Semantic Analyzers依赖的Context对象等。
```
DriverContext driverCxt = new DriverContext(ctx); driverCxt.prepare(plan);

public DriverContext(Context ctx) {
    this.runnable = new ConcurrentLinkedQueue<Task<? extends Serializable>>();
    this.running = new LinkedBlockingQueue<TaskRunner>();
    this.ctx = ctx;
 }

public void prepare(QueryPlan plan) {
    // extract stats keys from StatsTask
    List<Task<?>> rootTasks = plan.getRootTasks();
    NodeUtils.iterateTask(rootTasks, StatsTask.class, new Function<StatsTask>()  
    {
      public void apply(StatsTask statsTask) {
        statsTasks.put(statsTask.getWork().getAggKey(), statsTask);
      }
    });
 }
```
顺便提一下`Context`对象，在`Context`的源码注释当中提到， 每一个查询都要对应一个`Context`对象，不同查询之间`Context`对象是不可重用的， 执行完一个查询之后需要`clear`对应的`Context`对象（主要是语法分析用到的`temp`文件目录），在Hive的实现中也是这么做的。回顾上一篇文章，从`CliDriver`循环的读取用户指令，每读取到一条指令都要进行`processLine`，`processCmd`，`processLocalCmd`的处理，然后提交给`Driver`编译解析。`Context`对象是在`compile`函数中实例化的，也就说每一条查询都会创建一个`Context`对象，当执行完一条查询从`Driver`返回到`processLocalCmd`中时，都会调用`Driver`对象的`close`函数对`Context`进行清理（`ctx.clear`），这样就保证了一条查询对应一个`Context`对象。对于`DriverContext`对象也是类似，在`execute`函数中实例化，`Driver`的`close`函数中关闭（`driverCtx.shutdown`），和`Context`相比一个用来辅助语义分析，一个用来辅助任务执行。还有，我们发现在`processCmd`函数中通过`CommandProcessorFactory`设置了`Driver`类的实例对象，也就是每一条查询都需要一个`Driver`对象进行处理，那这些`Driver`对象之间是否可以共享呢？答案是肯定的，在`CommandProcessorFactory`中维持了一个`HiveConf`到`Driver`的Map，每次获取`Driver`对象时都是根据conf对象来查找到的，如果不存在才重新创建一个`Driver`对象，而`HiveConf`对象又是在`CliDriver`的`run`方法中实例化的，与一个`CliSessionState`对应，所以`Driver`实例应该是与一个Cli的会话对应，同一个会话内部的查询共享一个`Driver`实例。

- **Manage and run all tasks**

扯得有点远，继续看`Driver`对查询任务的执行，在实例化`DriverContext`对象之后，就将查询计划plan中的任务放入到`DriverContext`的`runnable`队列中。
```
for (Task<? extends Serializable> tsk : plan.getRootTasks()) {
    assert tsk.getParentTasks() == null || tsk.getParentTasks().isEmpty();
    driverCxt.addToRunnable(tsk);
}
```

下面就开始运行任务Task，整个任务的运行由一个循环控制，只要`DriverContext`没有被关闭，并且`runnable`和`running`队列中还有任务就一直循环。为了方便描述，下文将一次对任务循环过程的每一步进行说明，这里只给出循环判断条件。
```
while (!destroyed && driverCxt.isRunning()) {}

public synchronized boolean isRunning() {
    return !shutdown && (!running.isEmpty() || !runnable.isEmpty());
}
```
 **1.**  **Put all the tasks into runnable queue**

在循环内部，首先不停的从`runnable`队列中抽取队首的任务，然后`launch`该任务。
```
 while (!destroyed && driverCxt.isRunning()) {
    // Launch upto maxthreads tasks
    Task<? extends Serializable> task;
    while ((task = driverCxt.getRunnable(maxthreads)) != null) {
        perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.TASK + task.getName() + "." + task.getId());
        TaskRunner runner = launchTask(task, queryId, noName, jobname, jobs, driverCxt);
        if (!runner.isRunning()) {
            break;
       }
 }
```



 **2.** **Launch a task**

 在launch一个任务的过程中，根据任务类型（是不是MapReduceTask或者ConditialTask），做一些操作(don't know what used for），将`DriverContext`当前已启动任务数`curJobNo`加1，然后根据配置文件conf，查询计划plan，执行上下文cxt（`DriverContext`），初始化一个任务，接着创建任务结果`TaskResult`对象和任务执行对象`TaskRunner`，将`TaskRunner`放入`DriverContext`的`running`队列中，表示该任务正在运行。最后，根据配置文件指定的任务运行模式，即是否支持并行运行，启动任务。
```
private TaskRunner launchTask(Task<? extends Serializable> tsk,
    String queryId, boolean noName,
    String jobname, int jobs, DriverContext cxt) throws HiveException {

    if (SessionState.get() != null) {
      SessionState.get().getHiveHistory().startTask(queryId, tsk,
                         tsk.getClass().getName());
    }

    if (tsk.isMapRedTask() && !(tsk instanceof ConditionalTask)) {
      if (noName) {
        conf.setVar(HiveConf.ConfVars.HADOOPJOBNAME, jobname + "(" +
        tsk.getId() + ")");
      }
      conf.set("mapreduce.workflow.node.name", tsk.getId());
      Utilities.setWorkflowAdjacencies(conf, plan);
      cxt.incCurJobNo(1);
      console.printInfo("Launching Job " + cxt.getCurJobNo() + " out of " + jobs);
    }

    tsk.initialize(conf, plan, cxt);
    TaskResult tskRes = new TaskResult();
    TaskRunner tskRun = new TaskRunner(tsk, tskRes);

    cxt.launching(tskRun);
    // Launch Task
    if (HiveConf.getBoolVar(conf, HiveConf.ConfVars.EXECPARALLEL)
        && (tsk.isMapRedTask() || (tsk instanceof MoveTask))) {
      // Launch it in the parallel mode, as a separate thread only for MR tasks
     //并发执行
      if (LOG.isInfoEnabled()){
        LOG.info("Starting task [" + tsk + "] in parallel");
      }
      tskRun.setOperationLog(OperationLog.getCurrentOperationLog());
      tskRun.start();
    } else {
      if (LOG.isInfoEnabled()){
        LOG.info("Starting task [" + tsk + "] in serial mode");
      }
     //顺序执行
      tskRun.runSequential();
    }
    return tskRun;
  }
```

**3. Poll a finished task**

完成任务的启动之后，将调用`DriverContext`的`pollFinished`函数，查看任务是否执行完毕，如果有任务完成，则将该任务出队，并将已完成的任务添加到钩子上下文`HookContext`中。

```
TaskRunner tskRun = driverCxt.pollFinished();
        if (tskRun == null) {
          continue;
}

hookContext.addCompleteTask(tskRun);

public synchronized TaskRunner pollFinished() throws InterruptedException {
    while (!shutdown) {
      Iterator<TaskRunner> it = running.iterator();
      while (it.hasNext()) {
        TaskRunner runner = it.next();
        if (runner != null && !runner.isRunning()) {
          it.remove();
          return runner;
        }
      }
      wait(SLEEP_TIME);
    }
    return null;
  }
```

**4. Handle the finished task**

针对一个已完成的任务，首先获取任务的结果对象`TaskResult`和退出状态, 如果任务非正常退出，则第一步先判断任务是否支持`Retry`，如果支持，关闭当前`DriverContext`，设置`jobTracker`为初始状态，抛出`CommandNeedRetry`异常，这个异常会在`CliDriver`的`processLocalCmd`中捕获，然后尝试重新处理该命令，参见上一篇文章的说明。如果任务不支持`Retry`，则启动备份任务`backupTask`（类似于回滚？），并添加到`runnable`队列，在下次循环过程中执行。如果没有`backupTask`，则查找用户配置`“hive.exec.failure.hooks”`,根据用户配置相应出错处理，并关闭`DriverContext`， 返回退出码。
```
Task<? extends Serializable> tsk = tskRun.getTask();
TaskResult result = tskRun.getTaskResult();

int exitVal = result.getExitVal();
   if (exitVal != 0) {
       if (tsk.ifRetryCmdWhenFail()) {
          driverCxt.shutdown();
          // in case we decided to run everything in local mode, restore the
          // the jobtracker setting to its initial value
           ctx.restoreOriginalTracker();
           throw new CommandNeedRetryException();
       }
       Task<? extends Serializable> backupTask = tsk.getAndInitBackupTask();
       if (backupTask != null) {
           setErrorMsgAndDetail(exitVal, result.getTaskError(), tsk);
           console.printError(errorMessage);
           errorMessage = "ATTEMPT: Execute BackupTask: " + backupTask.getClass().getName();
           console.printError(errorMessage);

               // add backup task to runnable
           if (DriverContext.isLaunchable(backupTask)) {
              driverCxt.addToRunnable(backupTask);
           }

           continue;

       } else {
            hookContext.setHookType(HookContext.HookType.ON_FAILURE_HOOK);
            // Get all the failure execution hooks and execute them.
            for (Hook ofh : getHooks(HiveConf.ConfVars.ONFAILUREHOOKS)) {
              perfLogger.PerfLogBegin(CLASS_NAME, PerfLogger.FAILURE_HOOK + ofh.getClass().getName());

              ((ExecuteWithHookContext) ofh).run(hookContext);

              perfLogger.PerfLogEnd(CLASS_NAME, PerfLogger.FAILURE_HOOK + ofh.getClass().getName());
            }
            setErrorMsgAndDetail(exitVal, result.getTaskError(), tsk);
            SQLState = "08S01";
            console.printError(errorMessage);
            driverCxt.shutdown();
            // in case we decided to run everything in local mode, restore the
            // the jobtracker setting to its initial value
            ctx.restoreOriginalTracker();
            return exitVal;
          }
  }
```
**5. Find children tasks**

最后调用`DriverContext`的`finished`函数，对完成的任务进行处理（处理逻辑没看懂）， 然后判断当前任务是否包含子任务，如果包含则依次将子任务添加到`runnable`队列，下次循环中被启动执行。
```
driverCxt.finished(tskRun);

if (tsk.getChildTasks() !=
    for (Task<? extends Serializable> child : tsk.getChildTasks()) {
        if (DriverContext.isLaunchable(child)) {
           driverCxt.addToRunnable(child);
        }
    }
}
```

**6. Do something before return**

当所有的任务都完成之后，如果发现`DriverContext`已经被关闭，表明任务取消，打印信息并返回对应的状态码。最后清楚任务执行中不完整的输出，并加载执行用户指定的`"hive.exec.post.hooks"`，完成对应的钩子功能。对于执行过程中出现的异常，`CommandNeedRetryException`将会直接向上抛出，其他`Exception`，直接打印出错信息。无论是否发生异常，只要能够获取到任务执行过程中的MapReduce状态信息，都将在finally语句块中打印。（限于篇幅，此处只给出部分代码，钩子的处理方式前文已经给出不再详述，异常处理的部分，有兴趣的执行查看）
```
//判断DriverContext是否被关闭
if (driverCxt.isShutdown()) {
        SQLState = "HY008";
        errorMessage = "FAILED: Operation cancelled";
        console.printError(errorMessage);
        return 1000;
}

//删除不完整的输出
HashSet<WriteEntity> remOutputs = new HashSet<WriteEntity>();
      for (WriteEntity output : plan.getOutputs()) {
        if (!output.isComplete()) {
          remOutputs.add(output);
        }
 }

 for (WriteEntity output : remOutputs) {
     plan.getOutputs().remove(output);
 }

```
最后的最后，如果所有的任务都正常执行完毕，此次查询完成，plan.setDone()，打印OK~

### PostRunHook and return
还没完~当`execute`函数执行完成后，返回到`runInternal`函数中，接着释放锁，与之前的`PreRunHook`相对应，还需要加载相应用户自定义的`PostRunHook`（代码不再重复），最后才调用`creatProcessorResponse`，创建响应对象`CommandProcessorResponse`并返回。
```
private CommandProcessorResponse createProcessorResponse(int ret) {
    return new CommandProcessorResponse(ret, errorMessage, SQLState, downstreamError);
 }

```



  [2]: hivea1.png
