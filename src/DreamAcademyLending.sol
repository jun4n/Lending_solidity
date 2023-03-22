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


     // 0.1%는 1/1000이었다는거. 그런데 이렇게 계산하면 조금 오차가 있는거 같기도 함.
    // 한블록당 12초
    // 24시간 => 7200블록
    // 1초마다 이자가 쌓이긴 하는데 결과적으로 24시간동안 쌓인 금액과 동일해져야 한다. => 12초마다의 이자를 계산
    // 원금 + (원금 * 1/1000) => 하루 복리 받은 금액
    // 원금 * (1 + x)**7200 => 12초마다 복리로 7200번 받은 금액
    // 위 두개 금액이 같아야함.
    // ( (원금) + (원금 * 1/1000) / 원금 ) ** (1/7200) - 1 = x


// 수정해야할점 => 가스비 해결
// 일단 이자를 받을 일도 없는 고객들까지 반복하고 있다는 점
// 하루가 지났어도 블록당 이자로 계산하고 있다는 점?
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
        // deposit한 토큰의 수
        uint deposit_usdc;
        uint deposit_eth;
        // 대출한 USDC의 수
        uint borrow_usdc;
        // 담보로 맡긴 ETH의 수
        uint collateral_eth;
        // 대출 당시의 ETH, USDC의 가치
        uint prev_eth;
        uint prev_usdc;
        // 유동성 공급량에 해당하는 이자
        uint fee;
        // 마지막 이자 계산 시간
        uint last_updated;
        // 몇번 청산됐는지 카운트
        uint liquidate_count;
        // 고객 주소록에 들어가 있는지 확인
        bool pushed;
    }
    mapping(address => CustomerInfo) customer;
    // 고객 주소를 관리해서 유동성 공급량만큼 이자 부여
    address[] customers_address;
    address[] borrow_customer;
    address[] deposit_customer;
    uint interest_per_sec;
    uint digit;

    modifier setInterest {
        uint interests;
        uint day;
        uint blocks;
        uint pool_deposit_usdc = ERC20(_usdc).balanceOf(address(this));
        for(uint i = 0; i< customers_address.length; i++){
            address c = customers_address[i];
            
            if(customer[c].borrow_usdc > 0){
                day = (block.number - customer[c].last_updated) / 7200;
                blocks = (block.number - customer[c].last_updated) % 7200;

                uint tmp = customer[c].borrow_usdc * 10 ** 12;
                for(uint j = 0; j < day; j++){
                    tmp = tmp + tmp / 1000;
                }
                for(uint j = 0; j < blocks; j++){
                    tmp = tmp + tmp / digit * interest_per_sec;
                }
                interests += (tmp / 10 ** 12) - customer[c].borrow_usdc;
                customer[c].borrow_usdc = tmp / 10 ** 12;
                customer[c].last_updated = block.number;
            }
        }
        for(uint i = 0; i < customers_address.length; i++){
            address c = customers_address[i];
            if(customer[c].deposit_usdc > 0){
                customer[c].fee += ((interests * 10 ** 12) / pool_deposit_usdc * customer[c].deposit_usdc) / 10 ** 12;
            }
        }
        _;
    }

    constructor (IPriceOracle _oracle, address usdc){
        oracle = _oracle;
        _usdc = usdc;
        // 1.3881950033933776e-07
        // 0.000000138819500339337760
        interest_per_sec = 138819500339337760;
        digit = 1000000000000000000000000;
    }

    function initializeLendingProtocol(address usdc) public payable {
        require(ERC20(usdc).transferFrom(msg.sender, address(this), msg.value));
        customer[msg.sender].deposit_eth += msg.value;
        customer[msg.sender].deposit_usdc += msg.value;
    }

    function deposit(address tokenAddress, uint256 amount) external payable setInterest {
        if (tokenAddress == _eth){
            require(msg.value == amount, "Insufficient ETH");
            // 대출이 있을 경우 담보로 들어간다? => 물타기인듯?
            // 담보금에 변경이 있을경우 청산 카운트도 초기화
            if(customer[msg.sender].borrow_usdc > 0){
                uint current_eth = oracle.getPrice(_eth);
                customer[msg.sender].prev_eth = 
                (
                    ( customer[msg.sender].prev_eth * customer[msg.sender].collateral_eth + current_eth * msg.value )
                    / ( msg.value + customer[msg.sender].collateral_eth )
                );
                customer[msg.sender].collateral_eth += msg.value;
                customer[msg.sender].liquidate_count = 0;
            }else{
                customer[msg.sender].deposit_eth += msg.value;
            }
        }else{
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "Insufficient USDC");
            customer[msg.sender].deposit_usdc += amount;
            require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount));
        }

        // customer_address를 돌면서 이자를 받기 때문에 중복적으로 들어가는건 곤란함.
        if(customer[msg.sender].pushed == false){
            customers_address.push(msg.sender);
        }
    }

    // tokenAddress를 amount만큼 빌리고 싶다
    // eth를 빌리는 경우는 없다.
    function borrow(address tokenAddress, uint256 amount) external setInterest{
        uint current_usdc = oracle.getPrice(_usdc);
        uint current_eth = oracle.getPrice(_eth);
        uint avaliable_amount;
        
        // may be overflow => overflow 시키려면 이더리움 개똥값되서 겁나 많이 넣어야할듯???
        avaliable_amount =  (((customer[msg.sender].deposit_eth * 10 ** 12) * current_eth / current_usdc) / 10 ** 12) /  2;
        
        require(avaliable_amount >= amount, "amount exceeds availiable amount");
        require(amount <= ERC20(_usdc).balanceOf(address(this)), "amount exceeds vault");
        
        uint collateral = amount * current_usdc / current_eth * 2;
        customer[msg.sender].borrow_usdc += amount;
        customer[msg.sender].collateral_eth += collateral;
        customer[msg.sender].deposit_eth -= collateral;
        customer[msg.sender].prev_eth = current_eth;
        customer[msg.sender].prev_usdc = current_usdc;
        customer[msg.sender].last_updated = block.number;
        customer[msg.sender].liquidate_count = 0;
        require(ERC20(tokenAddress).transfer(msg.sender, amount));
    }

    // tokenAddress를 amount만큼 갚겠다.
    // 가치는 생각하지 않아도 됨. 왜냐? 어차피 갚는사람이 amount만큼의 USDC를 가지고 온거니까
    function repay(address tokenAddress, uint256 amount) external payable setInterest{
        require(customer[msg.sender].borrow_usdc != 0, "Nothing to repay");
        require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "Not Approved");
        uint repaied = customer[msg.sender].collateral_eth * amount / customer[msg.sender].borrow_usdc;
        customer[msg.sender].borrow_usdc -= amount;
        customer[msg.sender].collateral_eth -= repaied;
        customer[msg.sender].deposit_eth += repaied;
        require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount));
    }

    // 담보를 청산하여 usdc 확보 => lending protocol 입장에서
    // thershold가 75%라는건 담보의 가치가 25%하락시 청산이 가능한 포지션이라는것
    // ** README **
    // can liquidate the whole position when the borrowed amount is less than 100,
    // otherwise only 25% can be liquidated at once.
    function liquidate(address user, address tokenAddress, uint256 amount) external setInterest{
        require(customer[user].borrow_usdc > 0);

        uint current_usdc = oracle.getPrice(_usdc);
        uint current_eth = oracle.getPrice(_eth);
        uint collateral = customer[user].collateral_eth;
        uint borrowed = customer[user].borrow_usdc;
        uint prev_eth = customer[user].prev_eth;
        uint prev_usdc = customer[user].prev_usdc;
        
        // usdc의 가치가 eth의 가치보다 떨어져 있을 경우 liquidate불가능. 왜냐면 USDC대비 ETH의 가치가 떨어지지만 안으면 되기 때문
        // 기존 가치/현재가치 해서 기존의 가치에서 현재 가치가 얼마나 떨어졌는지를 비교한다.
        require((current_usdc * 10 ** 2) / prev_usdc > (current_eth * 10 ** 2)/prev_eth, "[Can't Liquidate]] Collateral Value still higher than Liquidation Threshold");
        // 담보의 가치가 75%미만으로 떨어졌을경우
        // 담보의 가치는 담보의 수량을 포함함.
        // 기존 가치  * 담보의 수/ 현재가치 
        require((current_eth * 10 ** 2) * (collateral / 1e18) / (prev_eth) < 75, "[Can't Liquidate]] Collateral Value still higher than Liquidation Threshold");
        require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "Not Approved");

        // 100 ether 미만의 담보는 한번에 100%로 청산
        if(borrowed < 100 ether){
            require(amount == borrowed);
            customer[user].borrow_usdc = 0;
            customer[user].collateral_eth = 0;
            customer[user].liquidate_count = 0;
            require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount));
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success);
        }else{
            require(amount == borrowed / (4 - customer[user].liquidate_count));
            customer[user].borrow_usdc -= amount;
            customer[user].collateral_eth -= collateral / (4 - customer[user].liquidate_count);
            customer[user].liquidate_count += 1;
            // 청산당하다가 다시 deposit, borrow하는 경우는? => 물타기 해서 liquidation threshold를 넘지 안는다면 liquidate_count는 어떻게 해야하나? => 담보의 가치가 조정됐으므로 liquidation_count도 0
            if(customer[user].borrow_usdc == 0){
                customer[user].liquidate_count = 0;
            }
            require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount));
        }
    }

    // tokenAddress를 amount만큼 출금하겠다. 입금이 선행되야 하고, 출금 금액이 입금액보다 많아선 안됨.
    // 자체 청산 추가
    function withdraw(address tokenAddress, uint256 amount) external setInterest{
        if(tokenAddress == _eth){
            if(customer[msg.sender].deposit_eth >= amount){
                customer[msg.sender].deposit_eth -= amount;
                (bool success, ) = msg.sender.call{value: amount}("");
                require(success);
            }
            // 자체 청산 => 자체 청산시 ETH가 LT이상으로 떨어졌다고 가정하고 청산
            // borrow_value / (collateral_value - x) * 100 = 75
            // x = collateral_value - (borrow_value * 100)/76
            else{
                require(customer[msg.sender].collateral_eth > 0);
                uint current_usdc = oracle.getPrice(_usdc);
                uint current_eth = oracle.getPrice(_eth);
                uint x = (customer[msg.sender].collateral_eth * current_eth - (customer[msg.sender].borrow_usdc * current_usdc * 100) / 75 ) / 1e18 / 1e18;
                uint payback = customer[msg.sender].collateral_eth * x / (current_eth/1e18);
                require(payback == amount);
                customer[msg.sender].collateral_eth = 0;
                customer[msg.sender].borrow_usdc = 0;
                (bool success, ) = msg.sender.call{value: amount}("");
                require(success);
            }
        }else{
            require(customer[msg.sender].deposit_usdc + customer[msg.sender].fee >= amount, "Insufficient Balance");
            require(ERC20(tokenAddress).balanceOf(address(this)) >= amount, "Insufficient Vault");
            // 출금하려고 하는 금액이 deposit보다 클경우 이자 받은곳에서 충당.
            if(amount > customer[msg.sender].deposit_usdc){
                customer[msg.sender].fee -= (amount - customer[msg.sender].deposit_usdc);
                customer[msg.sender].deposit_usdc = 0;
                require(ERC20(tokenAddress).transfer(msg.sender, amount));
            } else{
                customer[msg.sender].deposit_usdc -= amount;
                require(ERC20(tokenAddress).transfer(msg.sender, amount));
            }
        }
    }
    function getAccruedSupplyAmount(address token) public setInterest returns(uint){
        if(token == _usdc){
            return customer[msg.sender].deposit_usdc + customer[msg.sender].fee;
        }else{
            return customer[msg.sender].deposit_eth;
        }
    }
}