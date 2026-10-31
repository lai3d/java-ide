package com.example.demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    @Value("${demo.greeting}")
    private String greeting;

    @GetMapping("/hello")
    public String hello(@RequestParam(defaultValue = "World") String name) {
        String message = greeting + ", " + name + "!";
        return message;
    }
}
