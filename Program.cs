// HttpClient GET request demonstration
// Performs a GET request to GitHub API and displays status code and response headers

using (var client = new HttpClient())
{
    Console.WriteLine($"ML-KEM supported: {System.Security.Cryptography.MLKem.IsSupported}");
    try
    {
        // Set User-Agent header (required by GitHub API)
        client.DefaultRequestHeaders.Add("User-Agent", "pqcheader-console-app");

        // Execute GET request
        Console.WriteLine("Sending GET request to https://www.quantumsafeaudit.com..");
        Console.WriteLine();
        
        var response = await client.GetAsync("https://www.quantumsafeaudit.com");
        
        // Ensure the request was successful
        response.EnsureSuccessStatusCode();
        
        // Display status code
        Console.WriteLine($"Status Code: {(int)response.StatusCode} {response.StatusCode}");
        Console.WriteLine();
        
        // Display response headers
        Console.WriteLine("Response Headers:");
        Console.WriteLine(new string('-', 50));
        
        foreach (var header in response.Headers)
        {
            Console.WriteLine($"{header.Key}: {string.Join(", ", header.Value)}");
        }
        
        // Also display content headers if present
        if (response.Content.Headers.Any())
        {
            Console.WriteLine();
            Console.WriteLine("Content Headers:");
            Console.WriteLine(new string('-', 50));
            
            foreach (var header in response.Content.Headers)
            {
                Console.WriteLine($"{header.Key}: {string.Join(", ", header.Value)}");
            }
        }
    }
    catch (HttpRequestException ex)
    {
        Console.WriteLine($"Error making HTTP request: {ex.Message}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Unexpected error: {ex.Message}");
    }
}
