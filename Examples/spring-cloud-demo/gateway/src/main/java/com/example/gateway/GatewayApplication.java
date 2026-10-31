package com.example.gateway;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.gateway.route.RouteLocator;
import org.springframework.cloud.gateway.route.builder.RouteLocatorBuilder;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class GatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(GatewayApplication.class, args);
    }

    /** GET /api/greetings/{name} → greeting-service /greetings/{name}. */
    @Bean
    RouteLocator routes(RouteLocatorBuilder builder, @Value("${demo.greeting-service-uri}") String greetingServiceUri) {
        return builder.routes()
                .route("greetings", r -> r.path("/api/greetings/**")
                        .filters(f -> f.stripPrefix(1))
                        .uri(greetingServiceUri))
                .build();
    }
}
