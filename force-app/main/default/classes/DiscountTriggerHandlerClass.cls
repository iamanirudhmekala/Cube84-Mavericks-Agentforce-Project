// HANDLER CLASS
public class DiscountTriggerHandlerClass {
    
    // Main method to get product prices and convert them based on contact's account country
    public static Map<Id, Decimal> getCurrencyConversionValues(List<String> productIds, Set<String> contactIds){
        System.debug('getCurrencyConversionValues called with productIds >>>' + productIds);
        System.debug('ContactIds ????' + contactIds);
        
        // Get product records with their price book entries
        List<Product2> productRecords = [SELECT Id, Name, 
                                        (SELECT Id, UnitPrice FROM PricebookEntries) 
                                        FROM Product2 
                                        WHERE Id IN :productIds 
                                        AND Id IN (SELECT Product2Id FROM PricebookEntry)];
        
        // Get contact records with their account's billing country
        List<Contact> contactAccountAddressCountry = [SELECT Id, Name, Account.Id, Account.Name, Account.BillingCountry 
                                                     FROM Contact 
                                                     WHERE Id IN :contactIds];
        
        System.debug('productRecords size >>>' + productRecords.size());
        System.debug('contactAccountAddressCountry >>>' + contactAccountAddressCountry);
        
        // Return empty map if no products or contacts found
        if(productRecords.isEmpty() || contactAccountAddressCountry.isEmpty()) {
            return new Map<Id, Decimal>();
        }
        
        // Get the target currency code from the first contact's account country
        String targetCurrencyCode = getCountryCurrencyCode(contactAccountAddressCountry[0].Account.BillingCountry);
        
        // If target currency is USD or we couldn't determine the currency, no conversion needed
        if(targetCurrencyCode == 'USD' || targetCurrencyCode == null) {
            Map<Id, Decimal> originalPrices = new Map<Id, Decimal>();
            for(Product2 prod : productRecords) {
                if(!prod.PricebookEntries.isEmpty()) {
                    originalPrices.put(prod.Id, prod.PricebookEntries[0].UnitPrice);
                }
            }
            return originalPrices;
        }
        
        // Important: Check if we can make a callout in the current context
        Boolean canMakeCallout = !Trigger.isExecuting && !System.isFuture() && !System.isBatch() && Limits.getLimitCallouts() > Limits.getCallouts();
        
        System.debug('Can make callout? ' + canMakeCallout);
        
        if (canMakeCallout) {
            Decimal conversionRate = getConversionRate('USD', targetCurrencyCode);
            return applyConversionRate(productRecords, conversionRate);
        } else {
            // If we can't make a callout in this context, we'll need to use @future
            System.debug('Cannot make callout in current context - returning original prices');
            
            Map<Id, Decimal> originalPrices = new Map<Id, Decimal>();
            for(Product2 prod : productRecords) {
                if(!prod.PricebookEntries.isEmpty()) {
                    originalPrices.put(prod.Id, prod.PricebookEntries[0].UnitPrice);
                }
            }
            
            // Schedule the asynchronous callout
            List<Id> prodIdList = new List<Id>();
            for(String s : productIds) {
                prodIdList.add(s);
            }
            
            System.debug('Calling future method from getCurrencyConversionValues');
            makeAsyncConversionRateCallout('USD', targetCurrencyCode, prodIdList);
            
            return originalPrices;
        }
    }
    
    // Method to apply conversion rates to all product prices
    private static Map<Id, Decimal> applyConversionRate(List<Product2> productRecords, Decimal conversionRate) {
        Map<Id, Decimal> convertedPrices = new Map<Id, Decimal>();
        for(Product2 prod : productRecords) {
            if(!prod.PricebookEntries.isEmpty()) {
                Decimal originalPrice = prod.PricebookEntries[0].UnitPrice;
                Decimal convertedPrice = originalPrice * conversionRate;
                convertedPrices.put(prod.Id, convertedPrice.setScale(2));
            }
        }
        return convertedPrices;
    }
    
    // Future method for making asynchronous callouts
    @future(callout=true)
    public static void makeAsyncConversionRateCallout(String fromCurrency, String toCurrency, List<Id> productIds) {
        System.debug('FUTURE METHOD CALLED - makeAsyncConversionRateCallout');
        System.debug('Parameters: fromCurrency=' + fromCurrency + ', toCurrency=' + toCurrency + ', productIds=' + productIds);
        
        try {
            Decimal conversionRate = getConversionRate(fromCurrency, toCurrency);
            
            System.debug('Async conversion rate obtained: ' + conversionRate);
            
            // Get the products with their price book entries
            List<Product2> products = [SELECT Id, Name, 
                                      (SELECT Id, UnitPrice FROM PricebookEntries) 
                                      FROM Product2 
                                      WHERE Id IN :productIds 
                                      AND Id IN (SELECT Product2Id FROM PricebookEntry)];
            
            // Now actually DO something with the converted prices
            // For example, store them in a custom field or create records
            for(Product2 prod : products) {
                if(!prod.PricebookEntries.isEmpty()) {
                    Decimal originalPrice = prod.PricebookEntries[0].UnitPrice;
                    Decimal convertedPrice = originalPrice * conversionRate;
                    
                    System.debug('Product: ' + prod.Name + ' Original Price: ' + originalPrice + 
                                ' Converted Price: ' + convertedPrice.setScale(2));
                    
                    // Here you would typically update a record, create a record, etc.
                    // Example (commented out):
                    // Product_Price_Conversion__c ppc = new Product_Price_Conversion__c(
                    //    Product__c = prod.Id,
                    //    Original_Price__c = originalPrice,
                    //    Converted_Price__c = convertedPrice.setScale(2),
                    //    Currency_Code__c = toCurrency
                    // );
                    // conversions.add(ppc);
                }
            }
            
            // Example (commented out):
            // if(!conversions.isEmpty()) {
            //    insert conversions;
            // }
        } catch(Exception e) {
            System.debug('Error in future method: ' + e.getMessage() + ' at line ' + e.getLineNumber());
        }
    }
    
    // Method to get the currency code based on country name
    public static String getCountryCurrencyCode(String countryName) {
        Map<String, String> countryCurrencyMap = new Map<String, String>{
            'UNITED STATES' => 'USD',
            'USA' => 'USD',
            'US' => 'USD',
            'CANADA' => 'CAD',
            'AUSTRALIA' => 'AUD',
            'UNITED KINGDOM' => 'GBP',
            'UK' => 'GBP',
            'GREAT BRITAIN' => 'GBP',
            'ENGLAND' => 'GBP',
            'EUROPE' => 'EUR',
            'FRANCE' => 'EUR',
            'GERMANY' => 'EUR',
            'SPAIN' => 'EUR',
            'ITALY' => 'EUR',
            'JAPAN' => 'JPY',
            'CHINA' => 'CNY',
            'INDIA' => 'INR',
            'BRAZIL' => 'BRL',
            'MEXICO' => 'MXN',
            'SOUTH AFRICA' => 'ZAR'
            // Add more country-currency mappings as needed
        };
        
        if(countryName == null) return 'USD';
        
        String upperCountry = countryName.toUpperCase();
        return countryCurrencyMap.containsKey(upperCountry) ? countryCurrencyMap.get(upperCountry) : 'USD';
    }
    
    // Method to get the currency conversion rate using an external API
    private static Decimal getConversionRate(String fromCurrency, String toCurrency) {
        System.debug('Getting conversion rate from ' + fromCurrency + ' to ' + toCurrency);
        
        // Call external currency API to get conversion rate
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        String apiKey = '4c6df0602d13ffb9576aedd6'; 
        request.setEndpoint('https://v6.exchangerate-api.com/v6/' + apiKey + '/pair/' + fromCurrency + '/' + toCurrency);
        request.setMethod('GET');
        
        try {
            HttpResponse response = http.send(request);
            if(response.getStatusCode() == 200) {
                // Parse the JSON response
                Map<String, Object> resultMap = (Map<String, Object>)JSON.deserializeUntyped(response.getBody());
                
                // Check if the API call was successful
                if(resultMap.containsKey('conversion_rate')) {
                    Decimal rate = (Decimal)resultMap.get('conversion_rate');
                    System.debug('Conversion rate: ' + rate);
                    return rate;
                } else {
                    System.debug
                        ('API Error: ' + response.getBody());
                    return 1.0; // Default to 1.0 (no conversion) in case of error
                }
            } else {
                System.debug('HTTP Error: ' + response.getStatusCode() + ' ' + response.getStatus());
                return 1.0; // Default to 1.0 (no conversion) in case of error
            }
        } catch(Exception e) {
            System.debug('Exception: ' + e.getMessage());
            return 1.0; // Default to 1.0 (no conversion) in case of exception
        }
    }
}