// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

/*
ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50% => 1ETH담보로 0.5ETH 만큼의 usdc
, liquidation threshold => 청산 임계값 는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
주요 기능 인터페이스는 아래를 참고해 만드시면 됩니다.
 */
 import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
 import "forge-std/console.sol";
 contract IPriceOracle {
   address public operator;
   mapping(address=>uint256) prices;

   constructor() {
       operator = msg.sender;
   }
   function getPrice(address token) external view returns (uint256) {
       require(prices[token] != 0, "the price cannot be zero");
       return prices[token];
   }
   function setPrice(address token, uint256 price) external {
       require(msg.sender == operator, "only operator can set the price");
       prices[token] = price;
   }
}


contract DreamAcademyLending {
    IPriceOracle oracle;
    address _usdc;
    address _eth;

    struct CustomerInfo{
        uint deposit_usdc;
        uint deposit_eth;
        uint borrow_usdc;
        uint borrow_eth;
        uint collateral_eth;
        uint collateral_usdc;
        uint last_updated;
    }
    mapping(address => CustomerInfo) customer;

    mapping(address => uint) deposit_usdc;
    mapping(address => uint) deposit_eth;
    mapping(address => uint) borrow_usdc;
    mapping(address => uint) borrow_eth;
    mapping(address => uint) collateral_usdc;
    mapping(address => uint) collateral_eth;
    uint pool_deposit_usdc;
    uint interest_per_sec;
    uint digit;
    // 0.1%는 1/1000이었다는거. 그런데 이렇게 계산하면 조금 오차가 있는거 같기도 함.
    // 한블록당 12초
    // 24시간 => 7200블록
    // 1초마다 이자가 쌓이긴 하는데 결과적으로 24시간동안 쌓인 금액과 동일해져야 한다.
    // 원금 + (원금 * 1/1000) => 하루 복리 받은 금액
    // 원금 * (1 + x)**86400 => 매초 복리로 받은 금액
    // 위 두개 금액이 같아야함.
    // ( (원금) + (원금 * 1/1000) / 원금 ) ** (1/86400) - 1 = x
    modifier setInterest {
        //if(customer[msg.sender].last_updated + 86400 <= block.number)
        //console.log("!!!!!!!!!!!~!@!@#!@# %d", (1000/digit) * ((digit+ interest_per_sec/digit) ** 86400));
        //console.log("%d", interest_per_sec/digit);
        if(customer[msg.sender].borrow_usdc > 0){
            customer[msg.sender].borrow_usdc = (customer[msg.sender].borrow_usdc) * ((1 + ) ** (block.number - customer[msg.sender].last_updated));
            console.log("2 %d", customer[msg.sender].borrow_usdc);
            /*for(uint i = customer[msg.sender].last_updated; i < block.number; i++){
                customer[msg.sender].borrow_usdc = customer[msg.sender].borrow_usdc + customer[msg.sender].borrow_usdc / 1000;
            }*/
        }
        if(customer[msg.sender].deposit_eth > 0){
            for(uint i = customer[msg.sender].last_updated; i < block.number; i++){
                customer[msg.sender].deposit_eth = customer[msg.sender].deposit_eth + customer[msg.sender].deposit_eth / 1000;
            }
        }
        if(customer[msg.sender].deposit_usdc > 0){
            for(uint i = customer[msg.sender].last_updated; i < block.number; i++){
                customer[msg.sender].deposit_usdc = customer[msg.sender].deposit_usdc + customer[msg.sender].deposit_usdc / 1000;
            }
        }
        customer[msg.sender].last_updated = block.number;
        console.log("%d", customer[msg.sender].last_updated);
        _;
    }

    constructor (IPriceOracle _oracle, address usdc){
        oracle = _oracle;
        _usdc = usdc;
        // 0.0000000115682909
        interest_per_sec = 115682909;
        digit = 10000000000000000;
    }

    function initializeLendingProtocol(address usdc) public payable {
        ERC20(usdc).transferFrom(msg.sender, address(this), msg.value);
        customer[msg.sender].deposit_eth += msg.value;
        customer[msg.sender].deposit_usdc += msg.value;
    }

    function deposit(address tokenAddress, uint256 amount) external payable{
        if (tokenAddress == _eth){
            //require(msg.value > 0, "must deposit more than 0 ether");
            require(msg.value == amount, "insufficient eth");
            customer[msg.sender].deposit_eth += msg.value;
        }else{
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "insufficient usdc");
            customer[msg.sender].deposit_usdc += amount;
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
            //pool_deposit_usdc = ERC20(tokenAddress).balanceOf(address(this));
        }
    }

    // tokenAddress를 amount만큼 빌리고 싶다
    function borrow(address tokenAddress, uint256 amount) external{
        uint current_usdc = oracle.getPrice(_usdc);
        uint current_eth = oracle.getPrice(_eth);
        uint avaliable_amount;
        if(tokenAddress == _usdc){
            avaliable_amount =  (customer[msg.sender].deposit_eth * current_eth / current_usdc) /  2;
            console.log("available: %d, amount: %d",avaliable_amount, amount);
            require(avaliable_amount >= amount, "need more deposit");
            require(amount <= ERC20(_usdc).balanceOf(address(this)), "we don't have that much zz");
            
            uint collateral = amount * current_usdc / current_eth * 2;
            customer[msg.sender].borrow_usdc += amount;
            customer[msg.sender].collateral_eth += collateral;
            customer[msg.sender].deposit_eth -= collateral;
            console.log("msg.sender deposit: %d", customer[msg.sender].deposit_eth);
            ERC20(tokenAddress).transfer(msg.sender, amount);
        }else{
            avaliable_amount =  (customer[msg.sender].deposit_usdc * current_usdc / current_eth) /  2;
            require(avaliable_amount >= amount, "need more deposit");
            require(avaliable_amount <= address(this).balance, "we don't have that much zz");
            
            uint collateral = amount * current_eth / current_usdc * 2;
            customer[msg.sender].borrow_eth += amount;
            customer[msg.sender].collateral_usdc += collateral;
            customer[msg.sender].deposit_usdc -= collateral;

            (bool success, ) = msg.sender.call{value: amount}("");
            require(success);
        }
        customer[msg.sender].last_updated = block.number;
    }
    // tokenAddress를 amount만큼 갚겠다.
    // USDC를 담보로 ETH를 빌리는 상황은 없는건가?
    function repay(address tokenAddress, uint256 amount) external payable setInterest{
        require(customer[msg.sender].borrow_eth != 0 || customer[msg.sender].borrow_usdc != 0, "Nothing to repay");
        if(tokenAddress == _usdc){
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "not approved");
            uint repaied = customer[msg.sender].collateral_eth * amount / customer[msg.sender].borrow_usdc;
            console.log("repaied: %d", repaied);
            customer[msg.sender].borrow_usdc -= amount;
            customer[msg.sender].collateral_eth -= repaied;
            customer[msg.sender].deposit_eth += repaied;
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        }
    }
    function liquidate(address user, address tokenAddress, uint256 amount) external{

    }
    // tokenAddress를 amount만큼 출금하겠다. 입금이 선행되야 하고, 출금 금액이 입금액보다 많아선 안됨.
    function withdraw(address tokenAddress, uint256 amount) external setInterest{
        console.log("amount borrow_usdc: %d", customer[msg.sender].borrow_usdc);
        if(tokenAddress == _eth){
            require(customer[msg.sender].deposit_eth >= amount, "you didn't deposit that much");
            require(address(this).balance >= amount, "we don't have that much bb");
            customer[msg.sender].deposit_eth -= amount;
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success);
        }
    }
    function getAccruedSupplyAmount(address token) public setInterest returns(uint){
        if(token == _usdc){
            console.log("deposit_usdc: %d", customer[msg.sender].deposit_usdc);
            return customer[msg.sender].deposit_usdc;
        }else{
            console.log("!!!!!!");
            return customer[msg.sender].deposit_eth;
        }
    }

}
