package com.example.common;

/** Shared by the services: the payload the greeting service returns. */
public record Greeting(String message, String servedBy) {
}
