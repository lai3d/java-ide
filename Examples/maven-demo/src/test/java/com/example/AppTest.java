package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AppTest {
    @Test
    void sumsSquares() {
        assertEquals(385, App.sumOfSquares(10));
        assertEquals(0, App.sumOfSquares(0));
    }
}
