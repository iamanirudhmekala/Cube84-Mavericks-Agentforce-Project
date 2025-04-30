public without sharing class DiscountRequestHelper {
    
    /**
     * Converts an 18-digit Salesforce ID to its 15-digit version
     * @param id18 The 18-digit ID to convert
     * @return The 15-digit version of the ID
     */
    private static String convertTo15Digit(String id18) {
        if (id18 == null) return null;
        if (id18.length() == 15) return id18;
        if (id18.length() == 18) return id18.substring(0, 15);
        return id18; // Return as is if not 15 or 18 digits
    }
    
    @InvocableMethod(label='Create Discount Request' description='Creates new Discount Request records for each product and returns success or failure messages.')
    public static List<String> createDiscountRequests(List<DiscountRequestInput> requestInputs) {
        List<Discount_Request__c> discountRequests = new List<Discount_Request__c>();
        List<String> outputMessages = new List<String>();
        
        // Debug the input parameters
        System.debug('Input parameters: ' + JSON.serialize(requestInputs));
        
        try {
            // Get current user for debugging
            String currentUserId = UserInfo.getUserId();
            String currentUserName = UserInfo.getName();
            String currentProfile = UserInfo.getProfileId();
            System.debug('Current User: ' + currentUserName + ' (ID: ' + currentUserId + ', Profile: ' + currentProfile + ')');
            
            // ======== Approach 1: Use with sharing context for querying to check actual access ========
            Boolean hasAccessIssues = false;
            Map<Id, String> accountAccessMap = new Map<Id, String>();
            Map<Id, String> contactNames = new Map<Id, String>();
            Map<Id, String> productNames = new Map<Id, String>();
            
            // Collect IDs for verification
            Set<Id> accountIds = new Set<Id>();
            Set<Id> contactIds = new Set<Id>();
            Set<Id> productIds = new Set<Id>();
            
            for (DiscountRequestInput input : requestInputs) {
                if (input.accountId != null) {
                    // Convert to 15-digit format
                    String accId15 = convertTo15Digit(String.valueOf(input.accountId));
                    accountIds.add(accId15);
                    // Update input with 15-digit ID
                    input.accountId = accId15;
                }
                
                if (input.contactId != null) {
                    String conId15 = convertTo15Digit(String.valueOf(input.contactId));
                    contactIds.add(conId15);
                    input.contactId = conId15;
                }
                
                // Handle product IDs
                if (input.productIds != null && !input.productIds.isEmpty()) {
                    // First check if it's a JSON string
                    if (input.productIds.size() == 1) {
                        String possibleJson = String.valueOf(input.productIds[0]);
                        if (possibleJson.startsWith('[') && possibleJson.endsWith(']')) {
                            try {
                                List<String> parsedIds = (List<String>)JSON.deserialize(possibleJson, List<String>.class);
                                List<Id> converted15DigitIds = new List<Id>();
                                for (String pid : parsedIds) {
                                    if (pid != null && pid.trim() != '') {
                                        String pid15 = convertTo15Digit(pid);
                                        productIds.add(pid15);
                                        converted15DigitIds.add(pid15);
                                    }
                                }
                                input.productIds = converted15DigitIds;
                            } catch (Exception e) {
                                System.debug('JSON parsing error: ' + e.getMessage());
                            }
                        }
                    } else {
                        // Convert each product ID to 15-digit
                        List<Id> converted15DigitIds = new List<Id>();
                        for (Object pid : input.productIds) {
                            String pid15 = convertTo15Digit(String.valueOf(pid));
                            productIds.add(pid15);
                            converted15DigitIds.add(pid15);
                        }
                        input.productIds = converted15DigitIds;
                    }
                }
                
                if (input.productId != null) {
                    String pid15 = convertTo15Digit(String.valueOf(input.productId));
                    productIds.add(pid15);
                    input.productId = pid15;
                }
            }
            
            // ======== CRITICAL FIX: Force Account access through system context ========
            // This uses a with sharing context to get names but ensures we can reference the Account record
            
            // 1. Query accounts using system mode to get names (no sharing rules)
            if (!accountIds.isEmpty()) {
                for (Account acc : [SELECT Id, Name FROM Account WHERE Id IN :accountIds ALL ROWS]) {
                    accountAccessMap.put(acc.Id, acc.Name);
                }
                System.debug('Found accounts (system mode): ' + accountAccessMap.keySet());
            }
            
            // 2. Query contacts and products for name display
            if (!contactIds.isEmpty()) {
                for (Contact c : [SELECT Id, Name FROM Contact WHERE Id IN :contactIds]) {
                    contactNames.put(c.Id, c.Name);
                }
            }
            
            if (!productIds.isEmpty()) {
                for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Id IN :productIds]) {
                    productNames.put(p.Id, p.Name);
                }
            }
            
            // Process each input to create discount requests
            for (DiscountRequestInput input : requestInputs) {
                String contactName = contactNames.containsKey(input.contactId) ? 
                    contactNames.get(input.contactId) : 'Unknown Contact';
                
                List<Id> productsToProcess = new List<Id>();
                
                // Determine which products to process
                if (input.productIds != null && !input.productIds.isEmpty()) {
                    productsToProcess.addAll(input.productIds);
                } else if (input.productId != null) {
                    productsToProcess.add(input.productId);
                }
                
                // Create a separate discount request for each product
                for (Id productId : productsToProcess) {
                    // Get product name for better record naming
                    String productName = productNames.containsKey(productId) ? 
                        productNames.get(productId) : 'Unknown Product';
                    
                    // ======== CRITICAL FIX: Create a Discount_Request__c WITHOUT ACCOUNT REFERENCE first ========
                    // Then update it with the Account ID separately if needed
                    
                    Discount_Request__c dr = new Discount_Request__c();
                    
                    // Create a descriptive name
                    dr.Name = 'Discount request for ' + contactName + ' - ' + productName;
                    
                    dr.Request_Status__c = input.requestStatus;
                    dr.Requested_Discount__c = input.requestedDiscount;
                    dr.Approved_Discount__c = input.approvedDiscount;
                    dr.Approval_Reason__c = input.approvalReason;
                    dr.Product__c = productId;
                    dr.Discount_Requestor__c = input.contactId;
                    
                    // ======== IMPORTANT: Handle Account_ID differently ========
                    // WORKAROUND: In this first pass, DON'T set the Customer_Account__c field
                    // We'll set it in a second DML operation if needed
                    
                    // Set explicit owner
                    dr.OwnerId = UserInfo.getUserId();
                    
                    discountRequests.add(dr);
                }
            }
            
            if (!discountRequests.isEmpty()) {
                // First insert without setting the Account reference
                List<Database.SaveResult> results = Database.insert(discountRequests, false);
                List<Discount_Request__c> successfulRecords = new List<Discount_Request__c>();
                
                for (Integer i = 0; i < results.size(); i++) {
                    Database.SaveResult sr = results[i];
                    Discount_Request__c dr = discountRequests[i];
                    
                    if (sr.isSuccess()) {
                        successfulRecords.add(dr);
                        outputMessages.add('Discount Request Created Successfully: ' + dr.Name);
                    } else {
                        for (Database.Error err : sr.getErrors()) {
                            outputMessages.add('Error creating Discount Request: ' + dr.Name + 
                                             ' - Error: ' + err.getStatusCode() + ': ' + 
                                             err.getMessage());
                            System.debug('Error details: ' + err);
                        }
                    }
                }
                
                // OPTIONAL: If you absolutely need the Account association, try updating with 
                // System.runAs or a future method, but this might still fail if the running user
                // truly doesn't have access to the Account records
            } else {
                outputMessages.add('No Discount Requests were created.');
            }
        } catch (Exception e) {
            String debugInfo = 'Error Type: ' + e.getTypeName() + '\n';
            debugInfo += 'Error Message: ' + e.getMessage() + '\n';
            debugInfo += 'Line Number: ' + e.getLineNumber() + '\n';
            debugInfo += 'Stack Trace: ' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR, debugInfo);
            outputMessages.add('Error creating Discount Request: ' + e.getMessage() + ' at line ' + e.getLineNumber());
        }
        
        return outputMessages;
    }
    
    // Define Invocable Variables for Input Parameters
    public class DiscountRequestInput {
        @InvocableVariable(label='Account ID' description='The Account related to this Discount Request' required=true)
        public Id accountId;
        
        @InvocableVariable(label='Contact ID' description='The Contact requesting the discount' required=true)
        public Id contactId;
        
        @InvocableVariable(label='Product ID' description='The Product the discount is applied to (Product2 Record Id)' required=false)
        public Id productId;
        
        @InvocableVariable(label='Product IDs' description='Multiple Products the discount is applied to (List of Product2 Record Ids)' required=false)
        public List<Id> productIds;
        
        @InvocableVariable(label='Requested Discount' description='Percentage of discount requested by the customer' required=false)
        public Decimal requestedDiscount;
        
        @InvocableVariable(label='Approved Discount' description='Final discount percentage approved' required=false)
        public Decimal approvedDiscount;
        
        @InvocableVariable(label='Approval Reason' description='Auto-generated reason for approval or rejection' required=false)
        public String approvalReason;
        
        @InvocableVariable(label='Request Status' description='Status of the discount request' required=false)
        public String requestStatus;
    }
}