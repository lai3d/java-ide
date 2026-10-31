package com.example.demo;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

@SpringBootTest
class HelloControllerTest {

    @Autowired
    private HelloController controller;

    @Test
    void greets() {
        assertThat(controller.hello("Java")).isEqualTo("Hello, Java!");
    }
}
