# What Robert C. Martin actually says about source-file organization

Research date: 2026-09-10

## Scope and conclusion

This report uses only Robert C. Martin’s 2008 book *Clean Code* and posts on his official Clean Coder Blog. “Direct” means the source states the point explicitly. “Inference” means a synthesis or a qualified conclusion from those sources; it is not presented as Martin’s wording.

Martin’s primary sources support a context-sensitive discipline rather than a universal file-layout law:

1. Within a source file or class, make the reading flow move from high-level concepts to lower-level detail, and keep related declarations close.
2. At repository and architecture level, make the system’s domain/use cases visible and keep frameworks, databases, and delivery mechanisms as details behind boundaries.
3. Make classes/modules cohesive and responsible to one coherent source of change; expose stable abstractions where a real boundary requires them, rather than manufacturing an interface for every class.

## 1. Source-file organization and declaration order

### Direct statements

- In *Clean Code*, chapter 5 presents a source file as something that should read like a newspaper: the important concepts come first and detail increases as the reader moves down the file. It also recommends keeping related concepts vertically close, placing variables near their uses, and avoiding separation into different files unless there is a good reason. [CC08]
- The same chapter says that, when one function calls another, the caller should generally appear above the callee so the module has a natural top-to-bottom flow. Martin also describes a Java-oriented class order: constants/static fields, instance fields, public functions, then private utilities placed near the public function that uses them. He labels the field ordering a standard Java convention and qualifies the caller-before-callee rule with “if at all possible,” so these are readability conventions, not a language-independent law. [CC08]
- In “Screaming Architecture,” Martin asks whether the top-level directory structure and highest-level source files reveal a healthcare, accounting, or inventory system—or instead reveal Rails, Spring, or Hibernate. His direct architectural test is that the repository should communicate the system’s use cases; frameworks, UI, web delivery, and databases are details that should not define the architecture. [SA11]
- In “Does Organization Matter?”, he says organization becomes increasingly important as systems become more complex, and that the organization appropriate for a 1,000-line program need not be the organization appropriate for a 100,000-line system. [ORG15]

### Inference

These statements establish a reading and dependency-oriented ordering principle, not a universal “one class per file,” “one declaration per file,” feature-folder, layer-folder, or alphabetical-order rule. Martin’s later examples make the qualification explicit: splitting related code into another class/source file is one possible degree of decoupling when it helps, while temporary co-location can be pragmatic when separation makes active work needlessly painful. [FP15] [TC18]

## 2. Public interfaces versus implementation details

### Direct statements

- The Dependency Rule in “The Clean Architecture” says source dependencies must point inward: inner business rules must not know names, formats, or mechanisms belonging to outer layers. Use cases can call an inner-owned output interface while an outer presenter implements it; the database, UI, and framework remain replaceable details outside the core. [CA12]
- In “A Little Architecture,” Martin states the same boundary idea in compilation terms: high-level policy should not mention low-level mechanism, and senders should own the interfaces that receivers implement. He also says each business rule should define only the data-access interface it actually needs, rather than depending on a broad database facility. [AA16]
- “FP vs. OO” gives the source-file version of this rule: polymorphic calls should let a caller avoid a source dependency on the callee’s implementation file. The caller and implementation depend on an abstraction in the opposite direction across the architectural boundary. [FP18]
- Martin’s “When to Mock” rejects mocking every class as a default. He says mocks belong primarily across architecturally significant boundaries; mocking internal collaborators couples tests to implementation details and can create an explosion of unnecessary interfaces. [MOCK14]
- “Future Proof” describes a graduated response to coupling: extract a function, move related code into a class/source file, or—when the boundary merits it—put the code behind a polymorphic interface. Martin explicitly says an interface with one implementation can be justified when it isolates a frequently changing module; the point is strategic decoupling, not interfaces as ceremony. [FP15]
- In “Interface Considered Harmful,” his criticism is aimed at Java’s requirement that a class announce `implements`/`extends` and thereby expose a relationship that could otherwise be hidden. Read together with the posts above, this is a critique of language syntax and representation, not a blanket rejection of interface boundaries. [ICH15]

### Inference

In this body of work, “public interface” means a stable contract at a meaningful boundary—not necessarily a separately declared interface file, and not a requirement that every class have an interface. The practical test is whether callers should be insulated from a volatile implementation, whether the boundary supports independent change/deployment/testing, and whether the abstraction is narrower than the implementation behind it.

## 3. Class and module responsibility

### Direct statements

- Martin states the Single Responsibility Principle as: “each software module should have one and only one reason to change.” He explains “responsibility” in terms of the people or tightly coupled group that would request the change, and restates the rule as gathering things that change for the same reason and separating things that change for different reasons. His examples separate payroll calculation, database persistence, and reporting rather than mixing them in one module. [SRP14]
- In “Functional Classes,” Martin defines a class as a group of cohesive, narrowly defined functions operating on an encapsulated data structure. He also says that a module can be a batch of functions manipulating internal or external data, and that systems should be partitioned into loosely coupled, internally cohesive elements. His websocket example separates transport mechanics from protocol rules behind a `relay` abstraction because those concerns change for different reasons. [FC23]
- “The Clean Architecture” permits an entity to be implemented either as an object with methods or as data structures plus functions. Its use-case layer owns application-specific business rules, while adapters translate external data and mechanisms. [CA12]
- *Clean Code*, chapter 10, says classes should be small in responsibility, not merely small in line count; a class name should describe the responsibilities it owns, and cohesion is the reason to keep related methods and fields together. [CC08]

### Inference

For Martin, “one responsibility” does not mean one method, one file, one class, or one framework layer. It means one coherent reason for change and a cohesive set of behavior/data. A module may therefore be a class, a namespace, or a focused group of functions; extraction is justified by responsibility, coupling, volatility, or a real architectural boundary.

## What the reviewed primary sources do not establish

The reviewed sources do not establish a universal rule that every class must have its own source file, that every public declaration must precede every private declaration in every language, or that every implementation must be hidden behind a named interface. The explicit ordering advice is mainly about reading flow and is partly framed as Java convention; the explicit interface advice is about meaningful dependency boundaries. Those negative conclusions are inferences from the reviewed corpus, not claims Martin makes verbatim.

## Primary sources

- [CC08 — Robert C. Martin, *Clean Code*, 1st ed. (Pearson)](https://www.pearson.com/en-us/subject-catalog/p/Martin-Clean-Code-A-Handbook-of-Agile-Software-Craftsmanship/P200000009044), especially chapters 5 (“Formatting,” pp. 75–90) and 10 (“Classes,” pp. 135–151); [official sample pages](https://www.informit.com/content/images/9780132350884/samplepages/9780132350884.pdf).
- [SA11 — “Screaming Architecture,” 2011-09-30](https://blog.cleancoder.com/uncle-bob/2011/09/30/Screaming-Architecture.html).
- [CA12 — “The Clean Architecture,” 2012-08-13](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html).
- [SRP14 — “The Single Responsibility Principle,” 2014-05-08](https://blog.cleancoder.com/uncle-bob/2014/05/08/SingleReponsibilityPrinciple.html).
- [MOCK14 — “When to Mock,” 2014-05-10](https://blog.cleancoder.com/uncle-bob/2014/05/10/WhenToMock.html).
- [ICH15 — “‘Interface’ Considered Harmful,” 2015-01-08](https://blog.cleancoder.com/uncle-bob/2015/01/08/InterfaceConsideredHarmful.html).
- [ORG15 — “Does Organization Matter?”, 2015-04-15](https://blog.cleancoder.com/uncle-bob/2015/04/15/DoesOrganizationMatter.html).
- [FP15 — “Future Proof,” 2015-10-30](https://blog.cleancoder.com/uncle-bob/2015/10/30/FutureProof.html).
- [AA16 — “A Little Architecture,” 2016-01-04](https://blog.cleancoder.com/uncle-bob/2016/01/04/ALittleArchitecture.html).
- [FP18 — “FP vs. OO,” 2018-04-13](https://blog.cleancoder.com/uncle-bob/2018/04/13/FPvsOO.html).
- [TC18 — “Too Clean?”, 2018-08-13](https://blog.cleancoder.com/uncle-bob/2018/08/13/TooClean.html).
- [FC23 — “Functional Classes,” 2023-01-18](https://blog.cleancoder.com/uncle-bob/2023/01/18/functional-classes.html).
