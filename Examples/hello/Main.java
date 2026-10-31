import java.util.List;
import java.util.Scanner;

/** A tiny program for trying JavaIDE: run with ⌘R, type a name in the Output panel's input field. */
public class Main {
    public static void main(String[] args) {
        var greeter = new Greeter("Hello");
        for (String name : List.of("Ada", "Grace", "Linus")) {
            System.out.println(greeter.greet(name));
        }
        System.out.print("Your name? ");
        Scanner in = new Scanner(System.in);
        if (in.hasNextLine()) {
            System.out.println(greeter.greet(in.nextLine().trim()));
        }
    }
}
