#!/bin/bash

# Copy the provided COBOL code to the source file
cat > src/program.cbl << 'EOF'
       IDENTIFICATION DIVISION.
       PROGRAM-ID. MORTGAGE01.
       ENVIRONMENT DIVISION.
       INPUT-OUTPUT SECTION.
       FILE-CONTROL.
           SELECT INPUT-FILE ASSIGN TO 'src/INPUT.DAT'
                  ORGANIZATION IS LINE SEQUENTIAL
                  FILE STATUS IS WS-INPUT-STATUS.
           SELECT OUTPUT-FILE ASSIGN TO 'data/OUTPUT.DAT'
                  ORGANIZATION IS LINE SEQUENTIAL
                  FILE STATUS IS WS-OUTPUT-STATUS.
       DATA DIVISION.
       FILE SECTION.
       FD INPUT-FILE.
       01 INPUT-REC.
          05 IR-APPLICATION-ID     PIC X(10).
          05 FILLER                PIC X(1).
          05 IR-CUSTOMER-NAME      PIC X(30).
          05 FILLER                PIC X(1).
          05 IR-LOAN-AMOUNT        PIC 9(10).
          05 FILLER                PIC X(1).
          05 IR-PROPERTY-VALUE     PIC 9(10).
          05 FILLER                PIC X(1).
          05 IR-DOWN-PAYMENT       PIC 9(10).
          05 FILLER                PIC X(1).
          05 IR-LOAN-TERM          PIC 9(2).
          05 FILLER                PIC X(1).
          05 IR-INTEREST-RATE      PIC 9(3)V9(2).
       FD OUTPUT-FILE.
       01 OUTPUT-REC              PIC X(80).
       WORKING-STORAGE SECTION.
       77 WS-INPUT-STATUS         PIC XX.
       77 WS-OUTPUT-STATUS        PIC XX.
       77 WS-EOF-FLAG             PIC X VALUE 'N'.
          88 WS-EOF               VALUE 'Y'.
          88 WS-NOT-EOF           VALUE 'N'.
       77 WS-ERROR-FLAG           PIC X VALUE 'N'.
          88 WS-ERROR             VALUE 'Y'.
          88 WS-NO-ERROR          VALUE 'N'.
       77 WS-MIN-DOWN-PAYMENT     PIC 9(10).
       77 WS-MONTHLY-RATE         PIC 9(3)V9(6).
       77 WS-TOTAL-MONTHS         PIC 9(4).
       77 WS-ANNUITY-FACTOR       PIC 9(4)V9(9).
       77 WS-MONTHLY-PAYMENT      PIC 9(8)V9(2).
       77 WS-REMAINING-BALANCE    PIC 9(10)V9(2).
       77 WS-INTEREST-PART        PIC 9(8)V9(2).
       77 WS-PRINCIPAL-PART       PIC 9(8)V9(2).
       77 WS-MONTH-COUNTER        PIC 999.
       77 WS-TEMP-VALUE           PIC 9(10)V9(9).
       01 WS-OUTPUT-REC.
          05 FILLER               PIC X(80).
       01 WS-DECLINE-REC.
          05 DR-APPLICATION-ID    PIC X(10).
          05 DR-STATUS            PIC X(5).
          05 DR-DECLINE-REASON    PIC X(50).
          05 DR-FILLER            PIC X(15).
       01 WS-APPROVE-HEADER.
          05 AH-APPLICATION-ID    PIC X(10).
          05 AH-STATUS            PIC X(5).
          05 AH-FILLER            PIC X(65).
       01 WS-SCHEDULE-REC.
          05 SR-MONTH-NUMBER      PIC 9(3).
          05 FILLER               PIC X(1).
          05 SR-PAYMENT-AMOUNT    PIC 9(8).99.
          05 FILLER               PIC X(1).
          05 SR-INTEREST-PART     PIC 9(8).99.
          05 FILLER               PIC X(1).
          05 SR-PRINCIPAL-PART    PIC 9(8).99.
          05 FILLER               PIC X(1).
          05 SR-REMAINING-BALANCE PIC 9(10).99.
          05 SR-FILLER            PIC X(27).
       PROCEDURE DIVISION.
       MAIN-PROCEDURE.
           PERFORM OPEN-FILES THRU OPEN-FILES-EX
           IF WS-NO-ERROR
              PERFORM PROCESS-FILE THRU PROCESS-FILE-EX
                 UNTIL WS-EOF OR WS-ERROR
           END-IF
           PERFORM CLOSE-FILES THRU CLOSE-FILES-EX
           STOP RUN.
       OPEN-FILES.
           OPEN INPUT INPUT-FILE
           IF WS-INPUT-STATUS NOT = '00'
              MOVE 'Y' TO WS-ERROR-FLAG
           END-IF
           IF WS-NO-ERROR
              OPEN OUTPUT OUTPUT-FILE
              IF WS-OUTPUT-STATUS NOT = '00'
                 MOVE 'Y' TO WS-ERROR-FLAG
              END-IF
           END-IF
           IF WS-ERROR
           ELSE
              MOVE 'N' TO WS-EOF-FLAG
           END-IF.
       OPEN-FILES-EX.
           EXIT.
       PROCESS-FILE.
           READ INPUT-FILE
              AT END 
                 MOVE 'Y' TO WS-EOF-FLAG
              NOT AT END 
                 PERFORM PROCESS-APPLICATION THRU PROCESS-APPLICATION-EX
           END-READ.
       PROCESS-FILE-EX.
           EXIT.
       PROCESS-APPLICATION.
           COMPUTE WS-MIN-DOWN-PAYMENT = 
               IR-PROPERTY-VALUE * 0.15
           EVALUATE TRUE
               WHEN IR-DOWN-PAYMENT < WS-MIN-DOWN-PAYMENT
                   PERFORM CREATE-DECLINE THRU CREATE-DECLINE-EX
               WHEN IR-DOWN-PAYMENT >= WS-MIN-DOWN-PAYMENT
                   PERFORM CALCULATE-SCHEDULE THRU CALCULATE-SCHEDULE-EX
               WHEN OTHER
                   MOVE 'DATA-ERR' TO DR-STATUS
                   PERFORM CREATE-DECLINE THRU CREATE-DECLINE-EX
           END-EVALUATE.
       PROCESS-APPLICATION-EX.
           EXIT.
       CREATE-DECLINE.
           MOVE IR-APPLICATION-ID TO DR-APPLICATION-ID
           MOVE 'DENY' TO DR-STATUS
           MOVE 'INSUFFICIENT FUNDS FOR DOWN PAYMENT' 
             TO DR-DECLINE-REASON
           MOVE SPACES TO DR-FILLER
           MOVE WS-DECLINE-REC TO WS-OUTPUT-REC
           WRITE OUTPUT-REC FROM WS-OUTPUT-REC
           IF WS-OUTPUT-STATUS NOT = '00'
              MOVE 'Y' TO WS-ERROR-FLAG
           END-IF.
       CREATE-DECLINE-EX.
           EXIT.
       CALCULATE-SCHEDULE.
           COMPUTE WS-MONTHLY-RATE = 
               IR-INTEREST-RATE / 12 / 100
           COMPUTE WS-TOTAL-MONTHS = IR-LOAN-TERM * 12
           COMPUTE WS-TEMP-VALUE = (1 + WS-MONTHLY-RATE)
           COMPUTE WS-TEMP-VALUE = WS-TEMP-VALUE ** WS-TOTAL-MONTHS
           COMPUTE WS-MONTHLY-PAYMENT ROUNDED = 
               IR-LOAN-AMOUNT * 
               (WS-MONTHLY-RATE * WS-TEMP-VALUE) / 
               (WS-TEMP-VALUE - 1)
           MOVE IR-APPLICATION-ID TO AH-APPLICATION-ID
           MOVE 'APPRO' TO AH-STATUS
           MOVE SPACES TO AH-FILLER
           MOVE WS-APPROVE-HEADER TO WS-OUTPUT-REC
           WRITE OUTPUT-REC FROM WS-OUTPUT-REC
           IF WS-OUTPUT-STATUS NOT = '00'
              MOVE 'Y' TO WS-ERROR-FLAG
           END-IF
           IF WS-NO-ERROR
              MOVE IR-LOAN-AMOUNT TO WS-REMAINING-BALANCE
              PERFORM CREATE-SCHEDULE-EN THRU CREATE-SCHEDULE-EN-EX
                 VARYING WS-MONTH-COUNTER FROM 1 BY 1
                 UNTIL WS-MONTH-COUNTER > WS-TOTAL-MONTHS 
                    OR WS-ERROR
           END-IF.
       CALCULATE-SCHEDULE-EX.
           EXIT.
       CREATE-SCHEDULE-EN.
           COMPUTE WS-INTEREST-PART ROUNDED = 
               WS-REMAINING-BALANCE * WS-MONTHLY-RATE
           COMPUTE WS-PRINCIPAL-PART ROUNDED = 
               WS-MONTHLY-PAYMENT - WS-INTEREST-PART
           COMPUTE WS-REMAINING-BALANCE = 
               WS-REMAINING-BALANCE - WS-PRINCIPAL-PART
           IF WS-MONTH-COUNTER = WS-TOTAL-MONTHS
               IF WS-REMAINING-BALANCE > 0.01 OR 
                  WS-REMAINING-BALANCE < -0.01
                   COMPUTE WS-PRINCIPAL-PART = 
                       WS-PRINCIPAL-PART + WS-REMAINING-BALANCE
                   COMPUTE WS-MONTHLY-PAYMENT = 
                       WS-INTEREST-PART + WS-PRINCIPAL-PART
                   MOVE ZERO TO WS-REMAINING-BALANCE
               ELSE
                   MOVE ZERO TO WS-REMAINING-BALANCE
               END-IF
           END-IF
           MOVE WS-MONTH-COUNTER TO SR-MONTH-NUMBER
           MOVE WS-MONTHLY-PAYMENT TO SR-PAYMENT-AMOUNT
           MOVE WS-INTEREST-PART TO SR-INTEREST-PART
           MOVE WS-PRINCIPAL-PART TO SR-PRINCIPAL-PART
           MOVE WS-REMAINING-BALANCE TO SR-REMAINING-BALANCE
           MOVE SPACES TO SR-FILLER
           MOVE WS-SCHEDULE-REC TO WS-OUTPUT-REC
           WRITE OUTPUT-REC FROM WS-OUTPUT-REC
           IF WS-OUTPUT-STATUS NOT = '00'
              MOVE 'Y' TO WS-ERROR-FLAG
           END-IF.
       CREATE-SCHEDULE-EN-EX.
           EXIT.
       CLOSE-FILES.
           IF WS-INPUT-STATUS = '00' OR '05'
              CLOSE INPUT-FILE
           END-IF
           IF WS-OUTPUT-STATUS = '00' OR '05'
              CLOSE OUTPUT-FILE
           END-IF.
       CLOSE-FILES-EX.
           EXIT.
EOF

cobc -x -o src/programCOMP src/program.cbl

# Run the COBOL program
./src/programCOMP

rm src/programCOMP
