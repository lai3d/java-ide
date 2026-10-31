/** Builds greetings. Try ⌘-clicking {@code greet} in Main.java, or renaming it with ⌃⌘E. */
public record Greeter(String salutation) {
    public String greet(String name) {
        return salutation + ", " + (name.isBlank() ? "stranger" : name) + "!";
    }
}
