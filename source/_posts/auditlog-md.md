---
title: 一种使用自定义注解+切面统一收集审计日志的方式
toc: false
banner: /images/cat2018.jpg
date: 2018-01-19 14:23:39
tags:
    - Java
author: GSM
---

最近在做一个审计模块，想要实现的是为微服务各个模块提供一个审计日志服务，即各个微服务模块收集日志 + 日志存储在db/elk/hive，然后针对存储的审计日志做展示或者分析的一个服务。可以看出实现一个审计服务的三个关键地方是：

- 收集日志
- 存储日志
- 展示/分析日志

第一个关键地方是收集日志, 本文也想探讨下如何更低耦合的收集日志。
<!-- more -->
## 什么是审计日志

审计日志记录了系统用户操作了什么，以便对用户行为进行追踪和审计。最典型的审计日志：

- “张三新增了一个用户李四”；
- “张三给李四新增了一个管理员权限”

“张三新增了一个用户李四”这条日志主语是当前登录的用户"张三"，谓语是动作“新增”，宾语是用户“李四”，还需要记录使用的系统功能“用户管理。”

所以最基本日志需要包含字段：

- 操作人operator；
- 操作动作action. 审计模块一般针对“新增”，“修改”和“删除”和“登录”类型的操作做记录；
- 操作的功能function,例如角色管理，应用管理，用户管理；
- 操作的主体subject，例如新创建一个用户是李四, 李四就是操作的主体;
- 日志的创建时间createTime

## 记录审计日志的方法

假如我们系统有三个服务，用户服务，权限服务，角色服务，需要在用户/权限/角色相关操作上记录审计日志。最直观的做法是在每个服务中嵌入审计日志rpc服务。例如：

用户服务  -  新增用户代码：

```java
    public void addUser(UserDTO userDTO) {
       userService.addUser(userDTO);
       
       AuditLog auditLog= new AuditLog();
       auditLog.setOperator(getCurrentLoginUser());
       auditLog.setAction("新增")；
       auditLog.setFunction("用户管理");
       auditLog.setSubject(userDTO.getUserName());
       auditLogSerice.writeLog(auditLog);
    }
```
但是这种做法有一个很大的缺陷就是业务代码和审计日志服务高耦合。业务coder需要花费很大的时间去封装日志需要的参数，但是实际上他是不需要关注这些日志相关的事情的。另外业务代码也会被割裂，很难写出clean code 一段代码只做一件事的代码。

我想到的一种优化方式是使用自定义注解+AOP切面生成统一日志。

首先定义一个注解，该注解的目的是只要被该注解@Auditable注解过的方法，都会被切面接收到打印审计日志。
```java
    @Retention(RetentionPolicy.RUNTIME)
    @Target({ElementType.METHOD, ElementType.TYPE})
    public @interface Auditable {
        Action action();// 行为
        Function function(); //功能
    }

    public enum Action{
        ADD("增加"),
        DELETE("删除"),
        MODIFY("修改");
        private String description;
    
        private Action(String description) {
            this.description = description;
        }
    
        public String getDescription() {
            return this.description;
        }
    }

    public enum Function{
        ...
    }
```

再定义一个注解，该注解帮助切面捕获被@Audit注解的方法参数中的操作主体值（例如刚才的张三）
```java
    @Retention(RetentionPolicy.RUNTIME)
    @Target({ElementType.FIELD, ElementType.TYPE, ElementType.LOCAL_VARIABLE})
    public @interface AuditingTargetUsername {
        String value() default "";
    }
```
用户DTO可以如下定义：
```java
    @Data
    public class UserDTO implements Serializable{ // already use lombok
        @NotNull
        @AuditingTargetUsername
        private String name;
    }
```
切面
```java
    @Component
    @Aspect
    public class AuditAspect {
        @Resource
        private IAuditLogService auditLogService;
    
        @After(value = "@annotation(auditable)")
        @Transactional
        public void logAuditActivity(JoinPoint jp, Auditable auditable) {
            String action = auditable.actionType().getDescription();
            String function = auditable.function().getFunction();
            String valueFilledIntoSubject = extractTargetAudintUserFromAnnotation(jp.getArgs()[0]);
    
            AuditLog auditLog = new AuditLog();
            auditLog.setOperationFunctionType(function);
            auditLog.setFunctionType(action);
            auditLog.setCreatedAt(new Date());
            auditLog.setUpdatedAt(new Date());
            auditLog.setOpName(getCurrentLoginUser());//获取当前登录用户
            auditLog.setContent(getCurrentLoginUser() + actionType + subject + valueFilledIntoSubject);//张三新增了用户
            auditLogService.insert(auditLog);
        }
    
        private String extractTargetAudintUserFromAnnotation(Object obj){
            // ...
            return getSubjectValueViaAnnotation(obj);
        }
      
        private String getSubjectValueViaAnnotation(Object obj) {
            String result = null;
            try {
                for (Field f : obj.getClass().getDeclaredFields()) {
                    for (Annotation a : f.getAnnotations()) {
                        if (a.annotationType() == AuditingTargetUsername.class) {
                            f.setAccessible(true);
                            Field annotatedFieldName = obj.getClass().getDeclaredField(f.getName());
                            annotatedFieldName.setAccessible(true);
                            String annotatedFieldVal = (String) annotatedFieldName.get(obj);
                            result = annotatedFieldVal;
                        }
                    }
                }
            } catch (Exception e) {
            }
            return result;
        }
    }
```
## 总结

通过上述自定义注解+切面可以实现将具体业务和记录审计日志解耦，提高各自开发人员的效率，代码也更加好维护一些。但是这种方式无法实现某些个性化的日志。我将日志分为两种：

- 通用日志

日志需要确定的信息都是固定的，例如异常/错误日志，或者一些简单的审计日志场景，例如上例中审计日志只需要“动作”，操作的”功能“，操作的”主体“值，或者登陆用户的ip, 等等固定信息都是可以算为通用日志，利用切面去优化日志实现方式。

- 个性化日志

在上述场景中，如果想进一步在服务中查询出某些数据反映在审计日志中，这些数据可以理解为动态日志数据，切面是无法拿到的（因为切面是基于反射，只能拿到方法的输入输出参数）。举例子来说就是删除用户场景。前端传入删除用户id = 5：
```java
    @Auditable(actionType = ActionType.DELETE, function = Function.User)
    @RequestMapping("/delete")
    @ResponseBody
    public void delete(int userId){
        String userNameDeleted = userService.getUserById(userId);// 需要记录日志 “DELETE USER 张三“ 但是aop无法拿到，
        userInfoService.delete(userId);
    }
```

需要记录日志 “DELETE USER 张三“，但是这个张三切面是无法捕获到的。这种场景自定义注解+AOP就无法实现了。现在想来，还是只能依赖日志RPC服务和业务代码耦合在一起。
