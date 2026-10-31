package com.example;

import java.util.stream.IntStream;

public class App {
    /** Sum of the first {@code n} squares. */
    public static long sumOfSquares(int n) {
        return IntStream.rangeClosed(1, n).mapToLong(i -> (long) i * i).sum();
    }

    public static void main(String[] args) {
        System.out.println("sumOfSquares(10) = " + sumOfSquares(10));
    }
}
