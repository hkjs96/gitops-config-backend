# 테스트용 MSA 애플리케이션 구성 가이드

> GitOps 테스트를 위한 Spring Boot MSA 3개 서비스 구성.
> 이 가이드는 App Repo(별도 리포지토리) 관점이며,
> Config Repo 구성 및 ArgoCD 배포는 아래 참고:
> - 로컬 K8s 환경: [GUIDE.md](./GUIDE.md)
> - ArgoCD 마이그레이션 가이드 (EKS 운영): [GUIDE-EKS.md](./GUIDE-EKS.md)

---

## 기술 스택

- Java 21 (Eclipse Temurin)
- Spring Boot 3.5.0
- Spring Cloud Gateway 2025.0.0 (api-gateway)
- Gradle 8
- Docker multi-stage build

---

## 디렉토리 구조

```
msa-backend/
├── user-service/
│   ├── src/main/java/com/example/userservice/
│   │   ├── UserServiceApplication.java
│   │   └── api/UserController.java
│   ├── src/main/resources/
│   │   ├── application.yml
│   │   ├── application-dev.yml
│   │   └── application-stg.yml
│   ├── build.gradle
│   ├── settings.gradle
│   └── Dockerfile
├── order-service/                  # (동일 구조)
│   └── api/OrderController.java
└── api-gateway/
    ├── src/main/java/.../ApiGatewayApplication.java
    ├── src/main/resources/
    │   ├── application.yml         # Gateway 라우팅 설정
    │   ├── application-dev.yml
    │   └── application-stg.yml
    ├── build.gradle                # spring-cloud-starter-gateway
    ├── settings.gradle
    └── Dockerfile
```

---

## 1. user-service

### settings.gradle

```groovy
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}
rootProject.name = 'user-service'
```

### build.gradle

```groovy
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.5.0'
    id 'io.spring.dependency-management' version '1.1.7'
}

group = 'com.example'
version = '0.0.1-SNAPSHOT'

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories { mavenCentral() }

dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-web'
    implementation 'org.springframework.boot:spring-boot-starter-actuator'
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}

tasks.named('test') { useJUnitPlatform() }
```

### UserServiceApplication.java

```java
package com.example.userservice;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class UserServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}
```

### UserController.java

```java
package com.example.userservice.api;

import org.springframework.core.env.Environment;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.List;

@RestController
public class UserController {

    private final Environment environment;

    public UserController(Environment environment) {
        this.environment = environment;
    }

    public record UserDto(long id, String name, String env) {}

    @GetMapping("/users")
    public List<UserDto> users() {
        String active = (environment.getActiveProfiles().length > 0)
                ? environment.getActiveProfiles()[0] : "default";
        return List.of(
                new UserDto(1L, "jisu", active),
                new UserDto(2L, "minsu", active)
        );
    }
}
```

> `env` 필드에 현재 Spring profile을 반환하여 dev/stg 환경 구분을 눈으로 확인 가능.

### application.yml

```yaml
server:
  port: 8080
management:
  endpoints:
    web:
      exposure:
        include: health,info
  endpoint:
    health:
      probes:
        enabled: true
```

### application-dev.yml / application-stg.yml

```yaml
# application-dev.yml
app:
  env: dev
logging:
  level:
    root: DEBUG
```

```yaml
# application-stg.yml
app:
  env: stg
logging:
  level:
    root: INFO
```

### Dockerfile

```dockerfile
FROM gradle:8-jdk21 AS build
WORKDIR /workspace
COPY . .
RUN gradle clean bootJar --no-daemon

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /workspace/build/libs/*.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
```

---

## 2. order-service

user-service와 동일 구조. 차이점만 기술.

- `settings.gradle` → `rootProject.name = 'order-service'`
- `build.gradle` → user-service와 동일
- `Dockerfile` → user-service와 동일

### OrderController.java

```java
package com.example.orderservice.api;

import org.springframework.core.env.Environment;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import java.util.List;

@RestController
public class OrderController {

    private final Environment environment;

    public OrderController(Environment environment) {
        this.environment = environment;
    }

    public record OrderDto(String orderId, long userId, int amount, String env) {}

    @GetMapping("/orders")
    public List<OrderDto> orders() {
        String active = (environment.getActiveProfiles().length > 0)
                ? environment.getActiveProfiles()[0] : "default";
        return List.of(
                new OrderDto("ORD-1001", 1L, 12000, active),
                new OrderDto("ORD-1002", 2L, 34000, active)
        );
    }
}
```

---

## 3. api-gateway (Spring Cloud Gateway)

### settings.gradle

```groovy
rootProject.name = 'api-gateway'
```

### build.gradle

```groovy
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.5.0'
    id 'io.spring.dependency-management' version '1.1.7'
}

group = 'com.example'
version = '0.0.1-SNAPSHOT'

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

repositories { mavenCentral() }

ext { set('springCloudVersion', "2025.0.0") }

dependencies {
    implementation 'org.springframework.cloud:spring-cloud-starter-gateway'
    implementation 'org.springframework.boot:spring-boot-starter-actuator'
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}

dependencyManagement {
    imports {
        mavenBom "org.springframework.cloud:spring-cloud-dependencies:${springCloudVersion}"
    }
}

tasks.named('test') { useJUnitPlatform() }
```

### application.yml — Gateway 라우팅

```yaml
server:
  port: 8080
spring:
  main:
    web-application-type: reactive
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: http://user-service:80
          predicates:
            - Path=/users/**
          filters:
            - AddResponseHeader=X-Env, ${SPRING_PROFILES_ACTIVE:default}
        - id: order-service
          uri: http://order-service:80
          predicates:
            - Path=/orders/**
          filters:
            - AddResponseHeader=X-Env, ${SPRING_PROFILES_ACTIVE:default}
management:
  endpoints:
    web:
      exposure:
        include: health,info
  endpoint:
    health:
      probes:
        enabled: true
```

> `X-Env` 응답 헤더로 현재 환경을 확인할 수 있다.
> `uri: http://user-service:80` — Config Repo의 ExternalName Service를 통해 cross-namespace 라우팅.

---

## 4. Docker 이미지 빌드

```bash
cd msa-backend

# 빌드 (--network=host 로 Gradle 플러그인 다운로드 보장)
docker build --network=host -t user-service:dev-1 ./user-service
docker build --network=host -t order-service:dev-1 ./order-service
docker build --network=host -t api-gateway:dev-1 ./api-gateway
```

### 로컬 K8s (k3d) 환경

```bash
# stg 태그 (코드 동일, 태그만 다름)
docker tag user-service:dev-1 user-service:stg-1
docker tag order-service:dev-1 order-service:stg-1
docker tag api-gateway:dev-1 api-gateway:stg-1

# k3d 클러스터에 import
k3d image import \
  user-service:dev-1 user-service:stg-1 \
  order-service:dev-1 order-service:stg-1 \
  api-gateway:dev-1 api-gateway:stg-1 \
  -c argocd-lab
```

### Nexus 레지스트리 환경

```bash
# 태그 & push
NEXUS=<NEXUS_HOST>/<NEXUS_REPO>
for SVC in user-service order-service api-gateway; do
  docker tag ${SVC}:dev-1 ${NEXUS}/${SVC}:dev-1
  docker push ${NEXUS}/${SVC}:dev-1
done
```

> 이후 Config Repo에서 ArgoCD Application을 생성하면 배포가 시작된다.
> - 로컬: [GUIDE.md](./GUIDE.md)
> - EKS 운영: [GUIDE-EKS.md](./GUIDE-EKS.md)

---

## 5. 트러블슈팅

### Gradle 플러그인 다운로드 실패

Docker 빌드 시 `Plugin [id: 'org.springframework.boot'] was not found` 에러가 나면:

1. `settings.gradle`에 `pluginManagement` 블록이 있는지 확인
2. Docker 빌드에 `--network=host` 옵션 추가
3. `--no-cache` 옵션으로 캐시 초기화: `docker build --no-cache --network=host -t ...`
