-- Zmiana Wartości stałych
CREATE PROCEDURE ChangeFactors(@WZ INT, @WK INT) as
BEGIN
    UPDATE GlobalVars
    SET WZ = @WZ
    UPDATE GlobalVars
    SET WK = @WK
END
Go
-- Anulowanie zamówienia
CREATE PROCEDURE CancelOrder(@orderId AS int)
AS
BEGIN
    IF (NOT EXISTS(SELECT orderId FROM Orders WHERE orderId = @orderId))
        BEGIN
            RAISERROR ('Order does not exists', -1, -1)
            RETURN
        END
    IF (NOT ((SELECT O.receiveDate FROM Orders AS O WHERE O.orderId = @orderId) < GETDATE()))
        BEGIN
            RAISERROR ('Order already completed', -1, -1)
            RETURN
        END
    DELETE
    FROM Orders
    WHERE Orders.orderId = @orderId
    DELETE
    FROM OrderDetails
    WHERE OrderDetails.orderId = @orderId
END
GO

-- Anulowanie rezerwacji
CREATE PROCEDURE CancelReservation(@reservationId AS int)
AS
BEGIN
    IF (NOT EXISTS(SELECT reservationId FROM Reservations WHERE reservationId = @reservationId))
        BEGIN
            RAISERROR ('Reservation does not exists', -1, -1)
            RETURN
        END
    IF (NOT ((SELECT O.receiveDate FROM Orders AS O WHERE O.orderId = @reservationId) < GETDATE()))
        BEGIN
            RAISERROR ('Reservation already completed', -1, -1)
            RETURN
        END
    DECLARE @orderId AS int
    SET @orderId = (SELECT R.orderId FROM Reservations AS R WHERE R.reservationId = @reservationId)
    EXEC CancelOrder @orderId
    DELETE
    FROM Reservations
    WHERE Reservations.reservationId = @reservationId
    DELETE
    FROM ReservationDetails
    WHERE ReservationDetails.reservationId = @reservationId
END
GO

--Zmiana na zapłacone
CREATE PROCEDURE setOrderPaid(
    @orderId INT)
AS
BEGIN
    DECLARE @checkIsPaid BIT
    SET @checkIsPaid = (SELECT isPaid FROM Orders O WHERE O.orderId = @orderId)
    IF (@checkIsPaid = 0)
        BEGIN
            DECLARE @paid BIT
            SET @paid = 1
            UPDATE Orders
            SET isPaid = @paid
        END
    ELSE
        BEGIN
            RAISERROR ('Order is already paid.', -1, -1)
        END
END
GO
--pokaz wolne stoliki
CREATE PROCEDURE ShowFreeTablesAt(@datetime AS smalldatetime, @timespan AS int)
AS
BEGIN
    SELECT T.TableID
    FROM Tables AS T
    WHERE T.TableID NOT IN (SELECT T1.TableID
                            FROM Tables AS T1
                                     INNER JOIN ReservationDetails AS RD
                                                ON T1.TableID = RD.TableID
                                     INNER JOIN Reservations AS R
                                                ON RD.ReservationID = R.ReservationID
                            WHERE @datetime >= R.ReservationDate
                              AND @datetime <= DATEADD(MINUTE, @timespan, R.ReservationDate))
END
GO






CREATE PROCEDURE AddReservation @orderId INT,
                                @doneReservationDate INT,
                                @reservationDate INT,
                                @numberOfGuests INT,
                                @Confirmed INT,
                                @CompanyId INT
AS
BEGIN
    IF (@Confirmed IS NULL)
    BEGIN
        SET @Confirmed = 0
    end

    IF (NOT EXISTS(SELECT orderId FROM Orders WHERE orderId = @orderId) and @CompanyId is null)
        BEGIN
            RAISERROR ('No such orderId', -1, -1)
            RETURN
        END
    IF (@CompanyId is not null) --- rezerwacja na firmę
        begin
            INSERT INTO Reservations(CompanyID,DoneReservationDate, reservationDate, numberOfGuests, Confirmed)
            VALUES (@CompanyId, @doneReservationDate, @reservationDate, @numberOfGuests, @Confirmed)
            RETURN
        end
    IF (EXISTS(SELECT * FROM Orders WHERE orderId = @orderId AND isPaid = 1))
        BEGIN
            INSERT INTO Reservations(orderId,DoneReservationDate, reservationDate, numberOfGuests, Confirmed)
            VALUES (@orderId, @doneReservationDate, @reservationDate, @numberOfGuests, @Confirmed)
        END
    ELSE
        BEGIN
            DECLARE @customerId INT
            SET @customerId = (SELECT customerId from Orders where orderId = @orderId)
            IF ((SELECT COUNT(*)
                 FROM Orders AS O
                          INNER JOIN OrderDetails AS OD
                                     ON O.orderId = OD.orderID
                          LEFT OUTER JOIN Discounts D on O.DiscountID = D.DiscountID
                          LEFT OUTER JOIN DiscountParams DP on DP.ParamsID = D.ParamsID
                 WHERE O.customerId = @customerId
                 HAVING convert(money,SUM(OD.UnitPrice * OD.Quantity * ( 1 -IIF(D.DiscountType = 'lifetime', isnull(DP.R1, 0), isnull(DP.R2, 0)))))  > (SELECT WZ FROM GlobalVars)) >
                (SELECT WK FROM GlobalVars))
                BEGIN
                    INSERT INTO Reservations(orderId, DoneReservationDate, reservationDate, numberOfGuests, Confirmed)
                    VALUES (@orderId, @doneReservationDate, @reservationDate, @numberOfGuests, @Confirmed)
                END
            ELSE
                BEGIN
                    RAISERROR ('Client does not meet the requirements for reservation', -1, -1)
                    RETURN
                END
        END
END

CREATE PROCEDURE AddReservationDetails @ReservationId INT,
                                        @TableId INT
as
begin
    IF (NOT EXISTS(SELECT reservationId FROM Reservations WHERE reservationId = @reservationId))
    BEGIN
        RAISERROR ('No such reservationId', -1, -1)
        RETURN
    END
    IF (NOT EXISTS(SELECT tableId FROM Tables WHERE tableId = @tableId))
    BEGIN
        RAISERROR ('No such tableId', -1, -1)
        RETURN
    END

    INSERT into ReservationDetails (ReservationID, TableID) values
                                    (@ReservationId, @TableId)
end


---Menu z danego dnia
CREATE PROCEDURE MenuOfTheDay @date SMALLDATETIME
AS
begin
IF (@date IS NULL)
    BEGIN
        SET @date = GETDATE()
    END
SELECT P.ProductID, P.Name, P.Description,
    P.CategoryID
FROM Products AS P
INNER JOIN dbo.MenuDetails AS MD
ON P.ProductID = MD.ProductID
INNER JOIN dbo.Menus AS M
ON MD.menuId = M.menuId
WHERE @date BETWEEN M.inDate AND M.outDate
end


CREATE PROCEDURE InsertToMenu
    @menuId INT,
    @ProductId INT,
    @UnitPrice Money
AS
BEGIN
IF (NOT EXISTS(SELECT * FROM Menus WHERE @menuId = menuId))
    BEGIN
        RAISERROR ('No such menuId', -1, -1)
        RETURN
    END
IF (NOT EXISTS(SELECT * FROM Products WHERE @ProductId = ProductID))
    BEGIN
        RAISERROR ('No such itemId', -1, -1)
        RETURN
    END
IF(EXISTS(Select * from MenuDetails where MenuID = @menuId and ProductID = @ProductId))
    BEGIN
        UPDATE MenuDetails
            SET UnitPrice = @UnitPrice
            where ProductID = @ProductID and MenuID = @menuId
        RETURN
    END
INSERT INTO MenuDetails(menuId, ProductID, UnitPrice)
VALUES (@menuId, @ProductId, @UnitPrice)
END


CREATE PROCEDURE CreateMenu
    @inDate SMALLDATETIME,
    @outDate SMALLDATETIME
AS
BEGIN
IF (DATEDIFF(DAY, @inDate, @outDate) > 14 OR DATEDIFF(DAY, @inDate, @outDate) < 0)
BEGIN
RAISERROR ('Wrong outDate or inDate', -1, -1)
RETURN
END
INSERT INTO Menus(inDate, outDate)
VALUES (@inDate, @outDate)
END


CREATE PROCEDURE AddNewOrder
    @CustomerID INT,
    @EmployeeID INT,
    @OrderDate SMALLDATETIME,
    @ReceiveDate SMALLDATETIME,
    @IsPaid BIT,
    @TakeOut BIT,
    @DiscountType VARCHAR(20)
as
BEGIN
    If(@discountType NOT LIKE 'lifetime' OR @discountType NOT LIKE 'temporary' or @DiscountType is not null)
    BEGIN
        Raiserror ('Wrong discount type', -1, -1)
        RETURN
    end
    IF (@orderDate > @receiveDate)
    BEGIN
        RAISERROR ('Wrong orderDate or receiveDate', -1, -1)
        RETURN
    END
    IF (NOT EXISTS(SELECT customerId FROM Customers WHERE customerId = @CustomerId))
    BEGIN
        RAISERROR ('No such customerId', -1, -1)
        RETURN
    END
    IF (NOT EXISTS(SELECT employeeId FROM Employees WHERE employeeId = @employeeId))
    BEGIN
        RAISERROR ('No such employeeId', -1, -1)
        RETURN
    END
    IF(NOT EXISTS(SELECT DiscountID FROM Discounts
        where CustomerID = @CustomerID
        and DiscountType = @DiscountType
        and(UsedDate = null)
        ))
    BEGIN
        RAISERROR ('Customer does not have such discount', -1, -1)
        RETURN
    end

    DECLARE @DiscountId int
    SET @DiscountId = (SELECT top 1 DiscountID FROM Discounts
        where CustomerID = @CustomerID
        and DiscountType = @DiscountType
        and(UsedDate IS NULL))

    INSERT into Orders (CustomerID, EmployeeID, OrderDate, ReceiveDate, IsPaid, TakeOut, DiscountID)
    VALUES (@CustomerID, @EmployeeID, @OrderDate, @ReceiveDate, @IsPaid, @TakeOut, @DiscountId)

    if(@DiscountType = 'temporary')
    begin
        Update Discounts set UsedDate = GETDATE() WHERE DiscountID = @DiscountId
    end
end


CREATE PROCEDURE InsertToOrder @OrderId INT,
    @ProductID INT,
    @Quantinty INT
AS
BEGIN
    IF (NOT EXISTS(SELECT orderId FROM Orders WHERE orderId = @orderId))
    BEGIN
        RAISERROR ('No such orderId', -1, -1)
        RETURN
    END
    IF (NOT EXISTS(SELECT ProductID FROM Products WHERE ProductID = @ProductID))
    BEGIN
        RAISERROR ('No such ProductID', -1, -1)
        RETURN
    END

    declare @orderDate smalldatetime
    set @orderDate = (select OrderDate from Orders where OrderID = @OrderId)

    DECLARE @UnitPrice money
    SET @UnitPrice = (select top 1 UnitPrice from MenuDetails
                        inner join Menus M2 on M2.MenuID = MenuDetails.MenuID
                        where ProductID = @ProductID and InDate <= @orderDate
                        order by OutDate DESC
                                             )
    insert INTO OrderDetails (OrderID, ProductID, UnitPrice, Quantity)
    VALUES (@OrderId, @ProductID, @UnitPrice, @Quantinty)

end

CREATE PROCEDURE CreateInvoice @Date smalldatetime,
@CustomerId int,
@OrderID int,
@Address varchar(100),
@CityId int,
@PostalCode varchar(10)
AS
begin
    IF (@Date > GETDATE())
    BEGIN
        RAISERROR ('Wrong date', -1, -1)
        RETURN
    END
    IF (NOT EXISTS (SELECT customerId FROM Customers WHERE customerId = @customerId))
    BEGIN
        RAISERROR ('No such customerId', -1, -1)
        RETURN
    END
    IF (NOT EXISTS (SELECT orderId FROM Orders WHERE orderId = @orderId))
    BEGIN
        RAISERROR ('No such orderId', -1, -1)
        RETURN
    END
        declare @newIndex int
        set @newIndex = (select top 1 InvoiceID from Invoices order by InvoiceID desc) + 1


        Insert Into Invoices (Date, CustomerID, Address, CityID, PostalCode)
        values (@Date, @CustomerId, @Address, @CityId, @PostalCode)
        update Orders set InvoiceID = @newIndex where OrderID = @OrderID


end